; memorystick_low_level.asm
;--------------------;
; LOW LEVEL ROUTINES ;
;--------------------;
;
; Driver for the CH376S in 8-bit parallel mode.
;
; Protocol notes (CH376DS1.PDF, chapters 5 and 6.2):
; - Reading the command port returns the interface status:
;     bit 7 = interrupt flag, ACTIVE LOW (same as the INT# pin)
;     bit 4 = busy flag, active high
; - Commands $30..$40 (DISK_CONNECT, DISK_MOUNT, FILE_OPEN, BYTE_READ, ...)
;   take time. The CH376 signals their end with an interrupt. GET_STATUS
;   then returns the result and clears the interrupt. read_status_byte
;   therefore waits for the interrupt before it sends GET_STATUS.
; - Some USB sticks only answer DISK_MOUNT with USB_INT_SUCCESS after
;   several attempts (datasheet 5.17), so mount_disk retries.

PARA_STATE_INTB     equ %10000000       ; Interface status: 0 = interrupt pending
CMD_RET_SUCCESS     equ $51             ; Result byte of SET_USB_MODE

; Timeouts and retries. The pause routines are plain delay loops, so the
; real times depend on the CPU clock (long_pause is about 0.16 s at the
; Z80 Playground's 10 MHz, 0.1 s at 16 MHz and 0.2 s at 8 MHz).
CH376_INT_TIMEOUT   equ 16              ; x 65536 status polls, about 5 s at 10 MHz (3 s at 16 MHz, 7 s at 8 MHz)
CH376_SETUP_TRIES   equ 3               ; Complete reset/connect/mount cycles at start-up
CH376_CONNECT_TRIES equ 10              ; DISK_CONNECT attempts, one long_pause apart
CH376_MOUNT_TRIES   equ 25              ; DISK_MOUNT attempts, one long_pause apart

configure_memorystick:
    ; Resets the CH376, switches to USB host mode, waits for a disk and mounts it.
    ; Returns Z if the disk is mounted, NZ otherwise.
    ld b, CH376_SETUP_TRIES
configure_memorystick1:
    push bc
    call connect_to_usb_drive
    jr nz, failed_to_setup
    call connect_to_disk
    jr nz, failed_to_setup
    call long_pause                         ; Give the stick time to start up before mounting
    call long_pause
    call mount_disk
    jr nz, failed_to_setup
    pop bc
    ret                                     ; Z = success
failed_to_setup:
    call long_pause
    call long_pause
    call long_pause
    call long_pause
    pop bc
    djnz configure_memorystick1
    call message
    db 'CH376S error.',13,10,0
    or 1                                    ; Clear zero flag for failure
    ret

report_status_error:
    ; Prints the status in A as hex, followed by a newline.
    ; Returns A unchanged with the zero flag cleared. Destroys B.
    push af
    call show_a_as_hex
    call newline
    pop af
    ld b, a
    or 1                                    ; Clear zero flag
    ld a, b
    ret

;----------------------------------------------------------------
; Call this once at startup
reset_ch376_module:
    ld a, RESET_ALL
    call send_command_byte
    call long_pause
    call long_pause
    ret

;-----------------------------------------------------------------
check_module_exists:
    ld a, CHECK_EXIST
    Call send_command_byte

    ld a, 123               ; We send an arbitrary number
    Call send_data_byte

    call read_data_byte

    cp 255-123      ; The result is 255 minus what we sent in
    ret z
    call message
    db 'ERROR: CH376S module not found.',13,10,0
    ret

;-----------------------------------------------------------------
get_module_version:
    ld a, GET_IC_VER
    call send_command_byte

    call read_data_byte
    and %00011111

    call message
    db 'Found CH376S v',0 ; Mine is v3!!!
    call show_a_as_hex
    call newline
    ret

;-----------------------------------------------------------------
set_usb_host_mode:
    ; Switches to USB host mode 6 (enabled, SOF generated automatically).
    ; The CH376 answers with CMD_RET_SUCCESS on the data port (datasheet 5.9).
    ; Whether a disk is connected is checked later by connect_to_disk.
    ; Returns Z if ok.
    ld a, SET_USB_MODE
    call send_command_byte
    ld a, 6
    call send_data_byte
    call short_pause                        ; Mode switch takes about 10us
    call read_data_byte
    cp CMD_RET_SUCCESS
    ret z
    call message
    db 'ERROR setting USB host mode, result $',0
    jp report_status_error

;-----------------------------------------------------------------
connect_to_disk:
    ; Checks with DISK_CONNECT whether a USB disk is connected, with retries.
    ; Returns Z if connected, otherwise NZ and the last status in A.
    ; Preserves DE and HL.
    push de
    push hl
    ld b, CH376_CONNECT_TRIES
connect_to_disk1:
    push bc
    call clear_pending_interrupt
    ld a, DISK_CONNECT
    call send_command_byte
    call read_status_byte
    pop bc
    cp USB_INT_SUCCESS
    jr z, connect_to_disk_done
    push af
    push bc
    call long_pause
    pop bc
    pop af
    djnz connect_to_disk1
    call message
    db 'ERROR connecting to USB Disk, status $',0
    call report_status_error
connect_to_disk_done:
    pop hl
    pop de
    ret

;-----------------------------------------------------------------
mount_disk:
    ; Initialises the disk and its file system with DISK_MOUNT. Many USB sticks
    ; need several attempts after power-up, so this retries.
    ; Returns Z if mounted, otherwise NZ and the last status in A.
    ; Status codes: $1F = disk not ready / USB error, $82 = no disk,
    ; $84 = sector size not 512, $92 = partition type not supported,
    ; $A1 = no FAT12/16/32 file system (e.g. exFAT or NTFS).
    ; Preserves DE and HL.
    push de
    push hl
    ld b, CH376_MOUNT_TRIES
mount_disk1:
    push bc
    call clear_pending_interrupt
    ld a, DISK_MOUNT
    call send_command_byte
    call read_status_byte
    pop bc
    cp USB_INT_SUCCESS
    jr z, mount_disk_done
    cp USB_INT_DISCONNECT                   ; Disk removed: retrying won't help
    jr z, mount_disk_failed
    cp $80                                  ; $80 and above: no disk or file system error,
    jr nc, mount_disk_failed                ; retrying won't help either
    push af
    push bc
    call long_pause
    pop bc
    pop af
    djnz mount_disk1
mount_disk_failed:
    call message
    db 'ERROR mounting USB Disk, status $',0
    call report_status_error
mount_disk_done:
    pop hl
    pop de
    ret

;-----------------------------------------------------------------
read_disk_signature:
    ld a, RD_USB_DATA0
    call send_command_byte
    call read_data_byte                 ; A = length of bytes to now read
    cp 36
    jr nz, could_not_read_disk_sig

    ; Ignore the first 8 bytes
    ld b, 8
 read_disk_signature1:
    push bc
    call read_data_byte_silent
    pop bc
    djnz read_disk_signature1   

    ; Display the next 8 bytes (Manufacturer)
    ld b, 8
 read_disk_signature2:
    push bc
    call read_data_byte_silent
    call print_a
    pop bc
    djnz read_disk_signature2   
    call newline

    ; Display the next 16 bytes (Model)
    ld b, 16
 read_disk_signature3:
    push bc
    call read_data_byte_silent
    call print_a
    pop bc
    djnz read_disk_signature3

    ld a, ' '
    call print_a

    ; Display the next 4 bytes (Version)
    ld b, 4
 read_disk_signature4:
    push bc
    call read_data_byte_silent
    call print_a
    pop bc
    djnz read_disk_signature4   
    call newline
    ret

could_not_read_disk_sig:
    call message
    db 'ERROR reading disk sig.',13,10,0
    ret

connect_to_usb_drive:
    ; Resets the CH376 and switches it to USB host mode.
    ; Returns Zero flag = true if ok.
    call reset_ch376_module
    call set_usb_host_mode
    ret nz
    call long_pause                         ; Give a connected stick time to power up
    call long_pause
    call clear_pending_interrupt            ; Discard the USB_INT_CONNECT event, if any
    cp a                                    ; Set zero flag for success
    ret

create_file:
    ; pass in DE = pointer to filename
    push de
    ld a, SET_FILE_NAME
    call send_command_byte
    pop hl
    call send_data_string

    ld a, FILE_CREATE
    call send_command_byte

    call read_status_byte
    cp USB_INT_SUCCESS
    ret

open_file:
    ; Tells the module to use the filename from the filename_buffer.
    ; Returns z=true if ok to proceed.
    ; Pass in hl -> directory string, e.g. "/folder"
;      push hl
;      call message
;      db 'open_file:[',0
;  open_file1:
;      ld a, (hl)
;      cp 0
;      jr z, open_file2
;      call print_a
;      inc hl
;      jr open_file1

;  open_file2:
;      ld a, ']'
;      call print_a
;      call newline
;      pop hl

    ld a, SET_FILE_NAME
    call send_command_byte
    call send_data_string
    ld a, FILE_OPEN
    call send_command_byte
    call read_status_byte
    cp USB_INT_SUCCESS
    ret

close_file:
    ld a, FILE_CLOSE
    call send_command_byte
    ld a, 1                             ; 1 = update file size if necessary
    call send_data_byte
    call read_status_byte
    ret

create_directory:
    ; Tells the module to use the filename from the filename_buffer to create a directory of that name.
    ; Returns z=true if ok to proceed.
    ld hl, filename_buffer
; create_directory1:
;     ld a, (hl)
;     cp 0
;     jr z, create_directory2
;     inc hl
;     call print_a
;     jr create_directory1

create_directory2:

    ld a, SET_FILE_NAME
    call send_command_byte
    ld hl, filename_buffer
    call send_data_string
    ld a, DIR_CREATE
    call send_command_byte
    call read_status_byte
    cp USB_INT_SUCCESS
    ret

read_from_file:
    ; Ask to read 128 bytes from the current file into the dma_address area pointed to by DE.
    ; Returns Zero flag set for success, clear for fail.
    push de
    ld a, BYTE_READ
    call send_command_byte
    ld a, 128                           ; Request 128 bytes
    call send_data_byte
    ld a, 0
    call send_data_byte

    call read_status_byte
read_from_file1:
    cp USB_INT_DISK_READ                    ; This means "go ahead and read"
    jr z, read_from_file3
    cp USB_INT_SUCCESS                      ; Bizarrely this means we are finished
    jp z, read_from_file_cannot
    jr read_from_file_cannot

read_from_file3:
    ld a, RD_USB_DATA0                      ; Find out how many bytes are available to read
    call send_command_byte
    call read_data_byte                     ; A = number of bytes available to read

    ; If there are less than 128 bytes to read, fill the buffer with 0s first
    cp 128
    jr nc, read_from_file_128
    pop hl
    push hl
    push af
    ld b, 128
read_from_file_padding:
    ld (hl), 0
    inc hl
    djnz read_from_file_padding
    pop af

read_from_file_128:
    pop hl
    call read_data_bytes_into_hl        ; Read this block of data
    push hl
    ld a, BYTE_RD_GO
    call send_command_byte
    call read_status_byte
    pop hl
    ; All done, so return ZERO for success
    cp a                                ; set zero flag for success
    ret

 read_from_file_cannot:
    pop de
    or 1                                ; clear zero flag
    ret

copy_filename_to_buffer:
    ; Enter with hl->zero-terminated-filename-string
    ; Copies this to filename_buffer
    ld de, filename_buffer
copy_filename_to_buffer1:
    ld a, (hl)
    ld (de), a
    inc hl
    inc de
    cp 0
    ret z
    jr copy_filename_to_buffer1

send_data_byte:
    ; push af
    ; call message
    ; db 'send_data_byte ', 0
    ; pop af
    ; push af
    ; call show_a_as_hex
    ; call newline
    ; pop af
    out (mem_stick_data_port), a
    ;call tiny_pause
    call wait_til_not_busy
    ret
    
send_data_string:
    ; The string is pointed to by HL
    ld a, (hl)
    cp 0
    jr z, send_data_string_done
    push af
    push hl
    call send_data_byte
    pop hl
    pop af
    inc hl
    jp send_data_string
send_data_string_done:
    ld a, 0
    call send_data_byte
    ret

send_command_byte:
    ; push af
    ; call message
    ; db 'send_command_byte ',0
    ; pop af
    ; push af
    ; call show_a_as_hex
    ; call newline
    ; pop af
    out (mem_stick_command_port), a
    ;call tiny_pause
    call wait_til_not_busy
    ret
    
read_command_byte:
    ; call message
    ; db 'read_command_byte: ', 0
    in a, (mem_stick_command_port)
    ; push af
    ; call show_a_as_hex
    ; call newline
    ; pop af
    ret
    
read_data_byte:
    ; call message
    ; db 'read_data_byte: ', 0
    in a, (mem_stick_data_port)
    ; push af
    ; call show_a_as_hex
    ; call newline
    ; pop af
    ret
    
read_data_byte_silent:
    in a, (mem_stick_data_port)
    ret

read_data_bytes_into_buffer:
    ; The number of bytes should be in A.
    ; Read that many bytes into the buffer.
    ; The value of A is retained.
    ld hl, disk_buffer
read_data_bytes_into_hl:
    ; This entry point will read A bytes into the area pointed to by HL.
    ; On exit HL will point to the location after where the bytes were added.
    push af
    ld b, a
    ld c, mem_stick_data_port
 read_data_bytes_into_buffer1:
    inir                    ; A rare use of In, Increase & Repeat!!!
    pop af
    ret
    
wait_til_not_busy:
    ; call message
    ; db 'waiting...', 13, 10, 0
    ld bc, 60000            ; retry max 60000 times!!!
wait_til_not_busy1:
    push bc
    call read_command_byte
    and %00010000
    jp nz, wait_til_not_busy2
    pop bc
    ret
wait_til_not_busy2:
    call short_pause
    pop bc
    dec bc
    ld a, b
    or c
    jr nz, wait_til_not_busy1
    call message
    db '[USB TIMEOUT]', 13, 10, 0
    ret

wait_for_interrupt:
    ; Waits until the CH376 signals the end of the running command with an
    ; interrupt (bit 7 of the interface status goes low).
    ; Returns Z if the interrupt arrived, NZ on timeout.
    ; Destroys A and BC, preserves DE and HL.
    push de
    ld d, CH376_INT_TIMEOUT
    ld bc, 0
wait_for_interrupt1:
    in a, (mem_stick_command_port)
    and PARA_STATE_INTB
    jr z, wait_for_interrupt2
    dec bc
    ld a, b
    or c
    jr nz, wait_for_interrupt1
    dec d
    jr nz, wait_for_interrupt1
    call message
    db '[USB INT TIMEOUT]', 13, 10, 0
    or 1                                    ; Clear zero flag for timeout
wait_for_interrupt2:
    pop de
    ret

read_status_byte:
    ; Waits for the end of the running command, then reads its interrupt
    ; status with GET_STATUS, which also clears the interrupt.
    ; Use this only after commands that generate an interrupt ($30..$40).
    ; Returns the status in A. Preserves DE and HL.
    call wait_for_interrupt
read_status_byte_now:
    ld a, GET_STATUS
    call send_command_byte
    call read_data_byte
    ret

clear_pending_interrupt:
    ; If an interrupt is pending (e.g. a USB connect or disconnect event),
    ; reads and discards its status so that the next command starts clean.
    ; Preserves DE and HL.
    in a, (mem_stick_command_port)
    and PARA_STATE_INTB
    ret nz                                  ; No interrupt pending
    jr read_status_byte_now

; show_status:
;     call read_status_byte
;     push af
;     call report_on_status
;     pop af
;     ret                     ; The status is returned in A

; report_on_status:
;     cp USB_INT_SUCCESS
;     jr nz, ros1
;     call message
;     db 'USB_INT_SUCCESS',13,10,0
;     ret
; ros1:
;     cp USB_INT_CONNECT
;     jr nz, ros2
;     call message
;     db 'USB_INT_CONNECT',13,10,0
;     ret
; ros2:
;     cp USB_INT_DISCONNECT
;     jr nz, ros3
;     call message
;     db 'USB_INT_DISCONNECT',13,10,0
;     ret
; ros3:
;     cp USB_INT_BUF_OVER
;     jr nz, ros4
;     call message
;     db 'USB_INT_BUF_OVER',13,10,0
;     ret
; ros4:
;     cp USB_INT_USB_READY
;     jr nz, ros5
;     call message
;     db 'USB_INT_USB_READY',13,10,0
;     ret
; ros5:
;     cp USB_INT_DISK_READ
;     jr nz, ros6
;     call message
;     db 'USB_INT_DISK_READ',13,10,0
;     ret
; ros6:
;     cp USB_INT_DISK_WRITE
;     jr nz, ros7
;     call message
;     db 'USB_INT_DISK_WRITE',13,10,0
;     ret
; ros7:
;     cp USB_INT_DISK_ERR
;     jr nz, ros8
;     call message
;     db 'USB_INT_DISK_ERR',13,10,0
;     ret
; ros8:
;     cp YES_OPEN_DIR
;     jr nz, ros9
;     call message
;     db 'YES_OPEN_DIR',13,10,0
;     ret
; ros9:
;     cp ERR_MISS_FILE
;     jr nz, ros10
;     call message
;     db 'ERR_MISS_FILE',13,10,0
;     ret
; ros10:
;     cp ERR_FOUND_NAME
;     jr nz, ros11
;     call message
;     db 'ERR_FOUND_NAME',13,10,0
;     ret
; ros11:
;     cp ERR_DISK_DISCON
;     jr nz, ros12
;     call message
;     db 'ERR_DISK_DISCON',13,10,0
;     ret
; ros12:
;     cp ERR_LARGE_SECTOR
;     jr nz, ros13
;     call message
;     db 'ERR_LARGE_SECTOR',13,10,0
;     ret
; ros13:
;     cp ERR_TYPE_ERROR
;     jr nz, ros14
;     call message
;     db 'ERR_TYPE_ERROR',13,10,0
;     ret
; ros14:
;     cp ERR_BPB_ERROR
;     jr nz, ros15
;     call message
;     db 'ERR_BPB_ERROR',13,10,0
;     ret
; ros15:
;     cp ERR_DISK_FULL
;     jr nz, ros16
;     call message
;     db 'ERR_DISK_FULL',13,10,0
;     ret
; ros16:
;     cp ERR_FDT_OVER
;     jr nz, ros17
;     call message
;     db 'ERR_FDT_OVER',13,10,0
;     ret
; ros17:
;     cp ERR_FILE_CLOSE
;     jr nz, ros18
;     call message
;     db 'ERR_FILE_CLOSE',13,10,0
;     ret
; ros18:
;     call message
;     db 'UNKNOWN STATUS: ',0
;     call show_a_as_hex
;     call newline
;     ret


mem_stick_data_port equ 16
mem_stick_command_port equ 17

GET_IC_VER equ $01
SET_BAUDRATE equ $02
RESET_ALL equ $05
CHECK_EXIST equ $06
GET_FILE_SIZE equ $0C
SET_USB_MODE equ $15
GET_STATUS equ $22
RD_USB_DATA0 equ $27
WR_USB_DATA equ $2C
WR_REQ_DATA equ $2D
WR_OFS_DATA equ $2E
SET_FILE_NAME equ $2F
DISK_CONNECT equ $30
DISK_MOUNT equ $31
FILE_OPEN equ $32
FILE_ENUM_GO equ $33
FILE_CREATE equ $34
FILE_ERASE equ $35
FILE_CLOSE equ $36
DIR_INFO_READ equ $37
DIR_INFO_SAVE equ $38
BYTE_LOCATE equ $39
BYTE_READ equ $3A
BYTE_RD_GO equ $3B
BYTE_WRITE equ $3C
BYTE_WR_GO equ $3D
DISK_CAPACITY equ $3E
DISK_QUERY equ $3F
DIR_CREATE equ $40


; Statuses
USB_INT_SUCCESS equ $14
USB_INT_CONNECT equ $15
USB_INT_DISCONNECT equ $16
USB_INT_BUF_OVER equ $17
USB_INT_USB_READY equ $18
USB_INT_DISK_READ equ $1D
USB_INT_DISK_WRITE equ $1E
USB_INT_DISK_ERR equ $1F
YES_OPEN_DIR equ $41
ERR_MISS_FILE equ $42
ERR_FOUND_NAME equ $43
ERR_DISK_DISCON equ $82
ERR_LARGE_SECTOR equ $84
ERR_TYPE_ERROR equ $92
ERR_BPB_ERROR equ $A1
ERR_DISK_FULL equ $B1
ERR_FDT_OVER equ $B2
ERR_FILE_CLOSE equ $B4

ROOT_DIRECTORY:
    db '*',0

SLASH:
    db '/',0

;SAVE_FILENAME:
;    db 'TESTING',0

;TARGET_FILENAME:
;    db '/TARGET2.TXT',0

;NO_EXTENSION:
;    db '   ',0

;TXT_EXTENSION:
;    db 'TXT',0


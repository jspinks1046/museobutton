/* Name: usbdrvasm16.S
 * Project: AVR USB driver
 * Author: Christian Starkjohann
 * Creation Date: 2007-06-15
 * Tabsize: 4
 * Copyright: (c) 2007 by OBJECTIVE DEVELOPMENT Software GmbH
 * License: GNU GPL v2 (see License.txt) or proprietary (CommercialLicense.txt)
 * Revision: $Id$
 */

/* Do not link this file! Link usbdrvasm.S instead, which includes the
 * appropriate implementation!
 */

/*
General Description:
This file is the 16 MHz version of the asssembler part of the USB driver. It
requires a 16 MHz crystal (not a ceramic resonator and not a calibrated RC
oscillator).

See usbdrv.h for a description of the entire driver.

Since almost all of this code is timing critical, don't change unless you
really know what you are doing! Many parts require not only a maximum number
of CPU cycles, but even an exact number of cycles!
*/

;max stack usage: [ret(2), YL, SREG, YH, bitcnt, shift, x1, x2, x3, x4, cnt] = 12 bytes
;nominal frequency: 16 MHz -> 10.6666666 cycles per bit, 85.333333333 cycles per byte
; Numbers in brackets are clocks counted from center of last sync bit
; when instruction starts

USB_INTR_VECTOR:
;order of registers pushed: YL, SREG YH, [sofError], bitcnt, shift, x1, x2, x3, x4, cnt
    push    YL                  ;[-25] push only what is necessary to sync with edge ASAP
    in      YL, SREG            ;[-23]
    push    YL                  ;[-22]
    push    YH                  ;[-20]
;----------------------------------------------------------------------------
; Synchronize with sync pattern:
;----------------------------------------------------------------------------
;sync byte (D-) pattern LSb to MSb: 01010100 [1 = idle = J, 0 = K]
;sync up with J to K edge during sync pattern -- use fastest possible loops
;first part has no timeout because it waits for IDLE or SE1 (== disconnected)
waitForJ:
    sbis    USBIN, USBMINUS     ;[-18] wait for D- == 1
    rjmp    waitForJ
waitForK:
;The following code results in a sampling window of < 1/4 bit which meets the spec.
    sbis    USBIN, USBMINUS     ;[-15]
    rjmp    foundK              ;[-14]
    sbis    USBIN, USBMINUS
    rjmp    foundK
    sbis    USBIN, USBMINUS
    rjmp    foundK
    sbis    USBIN, USBMINUS
    rjmp    foundK
    sbis    USBIN, USBMINUS
    rjmp    foundK
    sbis    USBIN, USBMINUS
    rjmp    foundK
#if USB_COUNT_SOF
    lds     YL, usbSofCount
    inc     YL
    sts     usbSofCount, YL
#endif  /* USB_COUNT_SOF */
    rjmp    sofError
foundK:                         ;[-12]
;{3, 5} after falling D- edge, average delay: 4 cycles [we want 5 for center sampling]
;we have 1 bit time for setup purposes, then sample again. Numbers in brackets
;are cycles from center of first sync (double K) bit after the instruction
    push    bitcnt              ;[-12]
;   [---]                       ;[-11]
    lds     YL, usbInputBufOffset;[-10]
;   [---]                       ;[-9]
    clr     YH                  ;[-8]
    subi    YL, lo8(-(usbRxBuf));[-7] [rx loop init]
    sbci    YH, hi8(-(usbRxBuf));[-6] [rx loop init]
    push    shift               ;[-5]
;   [---]                       ;[-4]
    ldi     bitcnt, 0x55        ;[-3] [rx loop init]
    sbis    USBIN, USBMINUS     ;[-2] we want two bits K (sample 2 cycles too early)
    rjmp    haveTwoBitsK        ;[-1]
    pop     shift               ;[0] undo the push from before
    pop     bitcnt              ;[2] undo the push from before
    rjmp    waitForK            ;[4] this was not the end of sync, retry
; The entire loop from waitForK until rjmp waitForK above must not exceed two
; bit times (= 21 cycles).

;----------------------------------------------------------------------------
; push more registers and initialize values while we sample the first bits:
;----------------------------------------------------------------------------
haveTwoBitsK:
    push    x1              ;[1]
    push    x2              ;[3]
    push    x3              ;[5]
    ldi     shift, 0        ;[7]
    ldi     x3, 1<<4        ;[8] [rx loop init] first sample is inverse bit, compensate that
    push    x4              ;[9] == leap

    in      x1, USBIN       ;[11] <-- sample bit 0
    andi    x1, USBMASK     ;[12]
    bst     x1, USBMINUS    ;[13]
    bld     shift, 7        ;[14]
    push    cnt             ;[15]
    ldi     leap, 0         ;[17] [rx loop init]
    ldi     cnt, USB_BUFSIZE;[18] [rx loop init]
    rjmp    rxbit1          ;[19] arrives at [21]

;----------------------------------------------------------------------------
; Receiver loop (numbers in brackets are cycles within byte after instr)
;----------------------------------------------------------------------------

unstuff6:
    andi    x2, USBMASK ;[03]
    ori     x3, 1<<6    ;[04] will not be shifted any more
    andi    shift, ~0x80;[05]
    mov     x1, x2      ;[06] sampled bit 7 is actually re-sampled bit 6
    subi    leap, 3     ;[07] since this is a short (10 cycle) bit, enforce leap bit
    rjmp    didUnstuff6 ;[08]

unstuff7:
    ori     x3, 1<<7    ;[09] will not be shifted any more
    in      x2, USBIN   ;[00] [10]  re-sample bit 7
    andi    x2, USBMASK ;[01]
    andi    shift, ~0x80;[02]
    subi    leap, 3     ;[03] since this is a short (10 cycle) bit, enforce leap bit
    rjmp    didUnstuff7 ;[04]

unstuffEven:
    ori     x3, 1<<6    ;[09] will be shifted right 6 times for bit 0
    in      x1, USBIN   ;[00] [10]
    andi    shift, ~0x80;[01]
    andi    x1, USBMASK ;[02]
    breq    se0         ;[03]
    subi    leap, 3     ;[04] since this is a short (10 cycle) bit, enforce leap bit
    nop                 ;[05]
    rjmp    didUnstuffE ;[06]

unstuffOdd:
    ori     x3, 1<<5    ;[09] will be shifted right 4 times for bit 1
    in      x2, USBIN   ;[00] [10]
    andi    shift, ~0x80;[01]
    andi    x2, USBMASK ;[02]
    breq    se0         ;[03]
    subi    leap, 3     ;[04] since this is a short (10 cycle) bit, enforce leap bit
    nop                 ;[05]
    rjmp    didUnstuffO ;[06]

rxByteLoop:
    andi    x1, USBMASK ;[03]
    eor     x2, x1      ;[04]
    subi    leap, 1     ;[05]
    brpl    skipLeap    ;[06]
    subi    leap, -3    ;1 one leap cycle every 3rd byte -> 85 + 1/3 cycles per byte
    nop                 ;1
skipLeap:
    subi    x2, 1       ;[08]
    ror     shift       ;[09]
didUnstuff6:
    cpi     shift, 0xfc ;[10]
    in      x2, USBIN   ;[00] [11] <-- sample bit 7
    brcc    unstuff6    ;[01]
    andi    x2, USBMASK ;[02]
    eor     x1, x2      ;[03]
    subi    x1, 1       ;[04]
    ror     shift       ;[05]
didUnstuff7:
    cpi     shift, 0xfc ;[06]
    brcc    unstuff7    ;[07]
    eor     x3, shift   ;[08] reconstruct: x3 is 1 at bit locations we changed, 0 at others
    st      y+, x3      ;[09] store data
rxBitLoop:
    in      x1, USBIN   ;[00] [11] <-- sample bit 0/2/4
    andi    x1, USBMASK ;[01]
    eor     x2, x1      ;[02]
    andi    x3, 0x3f    ;[03] topmost two bits reserved for 6 and 7
    subi    x2, 1       ;[04]
    ror     shift       ;[05]
    cpi     shift, 0xfc ;[06]
    brcc    unstuffEven ;[07]
didUnstuffE:
    lsr     x3          ;[08]
    lsr     x3          ;[09]
rxbit1:
    in      x2, USBIN   ;[00] [10] <-- sample bit 1/3/5
    andi    x2, USBMASK ;[01]
    breq    se0         ;[02]
    eor     x1, x2      ;[03]
    subi    x1, 1       ;[04]
    ror     shift       ;[05]
    cpi     shift, 0xfc ;[06]
    brcc    unstuffOdd  ;[07]
didUnstuffO:
    subi    bitcnt, 0xab;[08] == addi 0x55, 0x55 = 0x100/3
    brcs    rxBitLoop   ;[09]

    subi    cnt, 1      ;[10]
    in      x1, USBIN   ;[00] [11] <-- sample bit 6
    brcc    rxByteLoop  ;[01]
    rjmp    overflow

.macro POP_STANDARD ; 14 cycles
    pop     cnt
    pop     x4
    pop     x3
    pop     x2
    pop     x1
    pop     shift
    pop     bitcnt
.endm
.macro POP_RETI     ; 7 cycles
    pop     YH
    pop     YL
    out     SREG, YL
    pop     YL
.endm

#include "asmcommon.S"

; USB spec says:
; idle = J
; J = (D+ = 0), (D- = 1)
; K = (D+ = 1), (D- = 0)
; Spec allows 7.5 bit times from EOP to SOP for replies

bitstuffN:
    eor     x1, x4          ;[5]
    ldi     x2, 0           ;[6]
    nop2                    ;[7]
    nop                     ;[9]
    out     USBOUT, x1      ;[10] <-- out
    rjmp    didStuffN       ;[0]
    
bitstuff6:
    eor     x1, x4          ;[4]
    ldi     x2, 0           ;[5]
    nop2                    ;[6] C is zero (brcc)
    rjmp    didStuff6       ;[8]

bitstuff7:
    eor     x1, x4          ;[3]
    ldi     x2, 0           ;[4]
    rjmp    didStuff7       ;[5]


sendNakAndReti:
    ldi     x3, USBPID_NAK  ;[-18]
    rjmp    sendX3AndReti   ;[-17]
sendAckAndReti:
    ldi     cnt, USBPID_ACK ;[-17]
sendCntAndReti:
    mov     x3, cnt         ;[-16]
sendX3AndReti:
    ldi     YL, 20          ;[-15] x3==r20 address is 20
    ldi     YH, 0           ;[-14]
    ldi     cnt, 2          ;[-13]
;   rjmp    usbSendAndReti      fallthrough

;usbSend:
;pointer to data in 'Y'
;number of bytes in 'cnt' -- including sync byte [range 2 ... 12]
;uses: x1...x4, btcnt, shift, cnt, Y
;Numbers in brackets are time since first bit of sync pattern is sent
;We don't match the transfer rate exactly (don't insert leap cycles every third
;byte) because the spec demands only 1.5% precision anyway.
usbSendAndReti:             ; 12 cycles until SOP
    in      x2, USBDDR      ;[-12]
    ori     x2, USBMASK     ;[-11]
    sbi     USBOUT, USBMINUS;[-10] prepare idle state; D+ and D- must have been 0 (no pullups)
    in      x1, USBOUT      ;[-8] port mirror for tx loop
    out     USBDDR, x2      ;[-7] <- acquire bus
; need not init x2 (bitstuff history) because sync starts with 0
    ldi     x4, USBMASK     ;[-6] exor mask
    ldi     shift, 0x80     ;[-5] sync byte is first byte sent
txByteLoop:
    ldi     bitcnt, 0x2a    ;[-4] [6] binary 00101010
txBitLoop:
    sbrs    shift, 0        ;[-3] [7]
    eor     x1, x4          ;[-2] [8]
    out     USBOUT, x1      ;[-1] [9] <-- out N
    ror     shift           ;[0] [10]
    ror     x2              ;[1]
didStuffN:
    cpi     x2, 0xfc        ;[2]
    brcc    bitstuffN       ;[3]
    lsr     bitcnt          ;[4]
    brcc    txBitLoop       ;[5]
    brne    txBitLoop       ;[6]

    sbrs    shift, 0        ;[7]
    eor     x1, x4          ;[8]
    ror     shift           ;[9]
didStuff6:
    out     USBOUT, x1      ;[-1] [10] <-- out 6
    ror     x2              ;[0] [11]
    cpi     x2, 0xfc        ;[1]
    brcc    bitstuff6       ;[2]
    sbrs    shift, 0        ;[3]
    eor     x1, x4          ;[4]
    ror     shift           ;[5]
    ror     x2              ;[6]
didStuff7:
    nop                     ;[7]
    nop2                    ;[8]
    out     USBOUT, x1      ;[-1][10] <-- out 7
    cpi     x2, 0xfc        ;[0] [11]
    brcc    bitstuff7       ;[1]
    ld      shift, y+       ;[2]
    dec     cnt             ;[4]
    brne    txByteLoop      ;[4]
;make SE0:
    cbr     x1, USBMASK     ;[7] prepare SE0 [spec says EOP may be 21 to 25 cycles]
    lds     x2, usbNewDeviceAddr;[8]
    lsl     x2              ;[10] we compare with left shifted address
    out     USBOUT, x1      ;[11] <-- out SE0 -- from now 2 bits = 22 cycles until bus idle
;2006-03-06: moved transfer of new address to usbDeviceAddr from C-Code to asm:
;set address only after data packet was sent, not after handshake
    subi    YL, 2           ;[0]
    sbci    YH, 0           ;[1]
    breq    skipAddrAssign  ;[2]
    sts     usbDeviceAddr, x2; if not skipped: SE0 is one cycle longer
skipAddrAssign:
;end of usbDeviceAddress transfer
    ldi     x2, 1<<USB_INTR_PENDING_BIT;[4] int0 occurred during TX -- clear pending flag
    USB_STORE_PENDING(x2)   ;[5]
    ori     x1, USBIDLE     ;[6]
    in      x2, USBDDR      ;[7]
    cbr     x2, USBMASK     ;[8] set both pins to input
    mov     x3, x1          ;[9]
    cbr     x3, USBMASK     ;[10] configure no pullup on both pins
    ldi     x4, 4           ;[11]
se0Delay:
    dec     x4              ;[12] [15] [18] [21]
    brne    se0Delay        ;[13] [16] [19] [22]
    out     USBOUT, x1      ;[23] <-- out J (idle) -- end of SE0 (EOP signal)
    out     USBDDR, x2      ;[24] <-- release bus now
    out     USBOUT, x3      ;[25] <-- ensure no pull-up resistors are active
    rjmp    doReturn


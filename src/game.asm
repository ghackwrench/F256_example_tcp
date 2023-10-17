; This is demo code. It is distributed in the hope that it
; will be useful, but WITHOUT ANY WARRANTY; without even the
; implied warranty of MERCHANTABILITY or FITNESS FOR A
; PARTICULAR PURPOSE.  - Jessie Oberreuter <gadget@moselle.com>.

            .cpu    "65c02"

*           = $0000     ; Kernel Direct-Page
mmu_ctrl    .byte       ?
io_ctrl     .byte       ?
reserved    .fill       6
mmu         .fill       8
            .dsection   dp
            .cerror * > $00ff, "Out of dp space."

*           = $0200
            .dsection   pages
            .dsection   data

*           = $2000     ; Application start.
            .text       $f2,$56     ; Signature
            .byte       1           ; 1 block
            .byte       1           ; mount at $2000
            .word       game.run    ; Start here
            .word       0           ; version
            .word       0           ; kernel
            .text       "game",0

            .dsection   code

game        .namespace

            .section    dp
frame       .byte       ?   ; Frame for next timer event.
cursor      .byte       ?   ; Cursor X offset.
tx_buf      .byte       ?   ; Buffer for the key.
src         .word       ?   ; Source pointer for copies.
dest        .word       ?   ; Dest pointer for copies.
state       .byte       ?   ; Zero if not connected.
            .send        

            .section    pages
rx_buf      .fill       256        
socket      .fill       256
            .send

            .section    data
event       .dstruct    kernel.event.event_t
            .send

            .section    code

run
          ; Init the screen.
            jsr     screen_init
            stz     cursor

          ; Schedule the first frame event.
            lda     #kernel.args.timer.FRAMES | kernel.args.timer.QUERY
            sta     kernel.args.timer.units
            jsr     kernel.Clock.SetTimer
            sta     frame
            jsr     timer_schedule
    
          ; Print a startup message.
            jsr     welcome
            
          ; Not connected yet.
            lda     #STATE.CLOSED
            sta     state
            jsr     print_state
    
          ; Run the event loop.
            jsr     cursor_on
            jmp     handle_events

welcome
            ldy     #0
_loop
            lda     _text,y
            beq     _done
            jsr     putchar
            iny
            bra     _loop
_done                        
            rts
_text       
            .text   "Trivial TCP client. "
            .text   "Press enter to connect.",13
            .byte   0

timer_schedule

          ; Compute the time for the next event.
            lda     frame
            clc
            adc     #60
            sta     frame
    
          ; Schedule the timer.
            lda     #kernel.args.timer.FRAMES
            sta     kernel.args.timer.units
            lda     frame
            sta     kernel.args.timer.absolute
_retry  
            jsr     kernel.Clock.SetTimer
            bcc     _done
          ; Stack is backed up ... should never happen...
            jsr     kernel.Yield
            bra     _retry
_done
            rts

tcp_open

          ; Give the kernel 256 bytes at 'socket' for
          ; tracking the state of this connection.
            stz     kernel.args.net.socket+0
            lda     #>socket
            sta     kernel.args.net.socket+1
            lda     #255
            sta     kernel.args.buflen
            
            ldy     #0
_copy
            lda     _args,y
            sta     kernel.args.net,y
            iny
            cpy     #8
            bne     _copy
            jmp     kernel.Net.TCP.Open
_args   
            .word   12345,2327  ; I think the kernel now picks the local.
            .byte   5,28,62,48  ; Should implement a DNS resolver...
        
tcp_close
          ; Close the socket.
            lda     #<socket
            sta     kernel.args.net.socket+0
            lda     #>socket
            sta     kernel.args.net.socket+1
            jmp     kernel.Net.TCP.Close            

handle_events

          ; Init the event buffer.
            lda     #<event
            sta     kernel.args.events.dest+0
            lda     #>event
            sta     kernel.args.events.dest+1

input_loop
            bit     kernel.args.events.pending
            ;beq     _yield
    
            jsr     kernel.NextEvent
            bcs     _yield

            lda     event.type
            cmp     #kernel.event.key.PRESSED
            beq     _kbd
            cmp     #kernel.event.net.TCP
            beq     _tcp
            cmp     #kernel.event.timer.EXPIRED
            beq     _timer
            bra     input_loop

_yield
      ; This is optional, but the kernel will need time to
      ; process IP traffic, so if we have nothing better to
      ; do, giving the kernel the rest of our time is nice.

            jsr     kernel.Yield
            bra     input_loop
        
_kbd
          ; Ignore meta keys.
            lda     event.key.flags
            bit     #event.key.META
            bne     input_loop

          ; Get the ASCII key value.
            lda     event.key.ascii

          ; CTRL-C exits.
            cmp     #3
            beq     exit

          ; CTRL-D closes the socket.
            cmp     #4
            beq     _close

            jsr     kbd
            bra     input_loop
        
_close
            jsr     tcp_close
            bra     input_loop

_tcp
            jsr     tcp
            bra     input_loop

_timer

          ; Twiddle a byte on the screen.
            lda     #2
            sta     io_ctrl
            ;inc     $c000

          ; Try to push an empty packet to force a retransmit.
          ; The modern internet barely needs this, but your
          ; wifi may be particularly bad...
            jsr     tcp_push
    
          ; Schedule the next event
            jsr     timer_schedule
            bra     input_loop
        
exit
          ; Close the socket.
          ; TODO: wait for it to finish.
            jmp     tcp_close

kbd
    ; Handle ASCII key presses.  
    ; Sends the pressed key immediately.  This is kinda
    ; silly, but much closer to what a game would do.

          ; If we're closed, try to connect.
          ; Ignore keys while not established.
            ldx     state
            cpx     #STATE.ESTABLISHED
            beq     _established
            cpx     #STATE.CLOSED
            beq     _open
            rts

_open
            jmp     tcp_open

_established

          ; Convert CRs to LFs since unix clients expect this.
            cmp     #13
            bne     _send
            lda     #10
            bra     _send

_send
          ; Stuff the key into a temp buffer.
          ; Could use event.key.ascii as the buffer,
          ; but that would be confusing :).
            sta     tx_buf
            
          ; A = # of bytes to send.
            lda     #1
            jmp     tcp_send
            
tcp_push
    ; Push an empty buffer.  This will keep NATs from
    ; dropping connections, and will help with crappy
    ; wifi conditions.  In theory, the internet is lossy;
    ; in practice, it rarely misses a beat.
    
            lda     state
            eor     #STATE.ESTABLISHED
            beq     _push
            rts
_push            
            lda     #0
            jmp     tcp_send

tcp_send:
    ; A = # of bytes (from tx_buf) to send.
    
          ; Set the # of bytes in the buffer.
            sta     kernel.args.net.buflen

          ; Set the socket.
            lda     #<socket
            sta     kernel.args.net.socket+0
            lda     #>socket
            sta     kernel.args.net.socket+1
    
          ; Set the tx buffer.
            lda     #<tx_buf
            sta     kernel.args.net.buf+0
            lda     #>tx_buf
            sta     kernel.args.net.buf+1
    
          ; Send the data!
            jmp     kernel.Net.TCP.Send

tcp
    ; Receive and display TCP data.
        
          ; Use our (hopefully) open socket.
            lda     #<socket
            sta     kernel.args.net.socket+0
            lda     #>socket
            sta     kernel.args.net.socket+1
    
          ; If the data received isn't for our socket,
          ; ignore it.
            jsr     kernel.Net.Match
            bcs     _reject
    
          ; Receive the data into our buffer.
            lda     #<rx_buf
            sta     kernel.args.net.buf+0
            lda     #>rx_buf
            sta     kernel.args.net.buf+1
            lda     #$ff
            sta     kernel.args.net.buflen
    
            jsr     kernel.Net.TCP.Recv
            bcs     _out

          ; Update the socket state.
            sta     state
    
          ; Print the bytes received.
            jsr     cursor_off
            ldy     #0
            bra     _next
_loop   
            lda     (kernel.args.net.buf),y
            jsr     putchar
            iny
_next   
            cpy     kernel.args.net.accepted
            bne     _loop
            jsr     cursor_on

          ; Re-display the socket state.
            jmp     print_state

_reject
            jmp     kernel.Net.TCP.Reject
_out
            rts

print_state
          ; Set source to the string for our current state.
            phx
            ldx     state
            lda     _states+0,x
            sta     src+0
            lda     _states+1,x
            sta     src+1
            plx

          ; Set dest to top of screen.
            lda     #$c0
            stz     dest+0
            sta     dest+1

          ; Print.
            jmp     print_src_to_dest

_states
            .dstruct    STATE

                  ; TCP states, from RFC793...
STATE               .struct
CLOSED              .word   str_closed
LISTEN              .word   str_listen
SYN_SENT            .word   str_syn_sent
SYN_RECEIVED        .word   str_syn_received
ESTABLISHED         .word   str_established
FIN_WAIT_1          .word   str_fin_wait_1
FIN_WAIT_2          .word   str_fin_wait_2
CLOSE_WAIT          .word   str_close_wait
CLOSING             .word   str_closing
LAST_ACK            .word   str_last_ack
TIME_WAIT           .word   str_time_wait
                    .ends

str_closed          .null   "closed       "
str_listen          .null   "listen       "
str_syn_sent        .null   "syn_sent     "
str_syn_received    .null   "syn_received "
str_established     .null   "established  "
str_fin_wait_1      .null   "fin_wait_1   "
str_fin_wait_2      .null   "fin_wait_2   "
str_close_wait      .null   "close_wait   "
str_closing         .null   "closing      "
str_last_ack        .null   "last_ack     "
str_time_wait       .null   "time_wait    "

print_src_to_dest
            phy
            ldy     #0
_loop
            lda     (src),y
            beq     _done
            sta     (dest),y
            iny
            bra     _loop
_done
            ply
            rts

screen_init
            phx
            phy

          ; Fill the attributes.
            lda     #3
            sta     io_ctrl
            lda     #$10
            jsr     _fill
            
          ; Fill the characters.
            lda     #2
            sta     io_ctrl
            lda     #32
            jsr     _fill
            
            ply
            plx
            rts
        
_fill
            ldx     #<$c000
            stx     dest+0
            ldx     #>$c000
            stx     dest+1
    
          ; Round X up to the next whole number of pages.
          ; Slight overkill, but keeps the code simple.
            ldx     #>(80*61)+256
            ldy     #0
_loop  
            sta     (dest),y
            iny
            bne     _loop
            inc     dest+1
            dex
            bne     _loop
            
            clc
            rts

cursor_on
          ; Switch the text under the cursor
          ; to white on yellow.
            lda     #$01
            bra     set_cursor
        
cursor_off
          ; Switch the text under the cursor
          ; to white on yellow.
            lda     #$10
            bra     set_cursor
        
set_cursor
        ; A = the text color attributes.
    
            phy
    
          ; Stash a copy of the current I/O setting.
            ldy     io_ctrl
            phy
    
          ; Switch to text color memory.
            ldy     #3
            sty     io_ctrl
    
          ; Set the attribute
            ldy     cursor
            sta     $c000+59*80,y
    
          ; Restore previous I/O setting.
            ply
            sty     io_ctrl
    
            ply
            clc
            rts
    
putchar
            pha
            jsr     cursor_off
            pla
    
            phy
            jsr     _putch
            ply
    
            jmp     cursor_on
    
_putch
            cmp     #32
            bcs     _ascii
            
            cmp     #8
            beq     _backspace
            
            cmp     #13
            beq     _cr
            
            cmp     #10
            beq     _lf
        
_done
            rts

_ascii
            ldy     cursor
            sta     $c000+80*59,y
            iny
            sty     cursor
            cpy     #80
            bne     _done

_cr
_lf
            stz     cursor
            jmp     scroll

_backspace
            ldy     cursor
            beq     _done
            dey
            sty     cursor
            bra     _done

        
scroll
        ; I would normally keep a ring buffer and re-draw the
        ; screen, but this isn't really a terminal program, and
        ; games won't generally operate that way.
            lda     #2
            sta     io_ctrl
            
            lda     #<$c000+80
            sta     src+0
            lda     #>$c000+80
            sta     src+1
    
            lda     #<$c000
            sta     dest+0
            lda     #>$c000
            sta     dest+1
            
          ; Round X up to the next whole number of pages.
          ; Slight overkill, but keeps the code simple.
            ldx     #>(80*60)+256
            ldy     #0
_loop  
            lda     (src),y
            sta     (dest),y
            iny
            bne     _loop
            inc     src+1
            inc     dest+1
            dex
            bne     _loop
            
            rts

            .send
            .endn
        

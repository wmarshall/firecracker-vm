'''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''
''
'' Firecracker VM Source
''  _________________________
'' |        Pin Table        |
'' |____pin____|___purpose___|
'' |           |             |
'' |   0-15    |   outputs   |
'' |    16     |     SDA     |
'' |    17     |     SCL     |
'' |    18     |    SCLK     |
'' |    19     |    MOSI     |
'' |    20     |    MISO     |
'' |    21     |     CS      |
'' |    22     |  soft reset |
'' |    23     | amp control |
'' |   24-27   |   unused    |
'' |   28,29   |   EEPROM    |
'' |   30,31   | USB header  |
'' |___________|_____________|
''
''
'' There are numerous protocols to communicate with Firecracker, so the first thing
'' that is done, is figuring out which configuration we are using. The following is how
'' to initialize each of the possible supported communication protocols. Wait at least 200ms
'' upon powerup before initializing. If an error occurs during initialization, pins 16 and
'' 20 will be driven high, indicating a selection was not made. Firecracker must then be soft
'' reset before being connected to again.
''
'' SPI -
''      First, set the clock to the desired clock polarity. If you just leave it at zero,
''      it defaults to a polarity of 0, which means clock is normally low and data propigated
''      on the rising edge, and read on the falling edge. The CS line will follow the clock
''      polarity. After the clock line is set, drive the MOSI line high to indicate SPI.
''      The Firecracker will respond by driving the MISO line high.
''      As soon as the MOSI line is dropped low, FVM will be ready for processing. FVM looks
''      for a positive edge, so if the line is high when FVM gets control from the boot
''      loader, it will not initialize until the line goes low, and is then raised again.
''      FVM will not respond on the MISO line if this is the case. Response time should be
''      within 5us.
''
''
'' Firecracker structure -
''      I'm seeing this playing out that we use roughly 16K of code and variable space.
''      Of course 8K of that is just the macro work area. The remaining 16K in RAM will
''      be used for Bottle Rocket LED arrays. There will be ~24K available in EEPROM
''      for macro storage with 8K being loaded at once.
''
''    - One COG is dedicated to executing just macros. It will execute NOPs until a
''      macro is executed by a second COG that is interpreting the input stream.
''    - A third COG will be used to recieve this input stream from SPI/I2C.
''    - A fourth COG will be responsible for the PWM drivers
''    - A fifth COG will act as the macro/memory manager, loading and storing macros
''      to and from EEPROM as requested. Right now I am implementing this in
''      SPIN because the EEPROM interface is very convinient and written in SPIN.
''      Any macro called will be verified and loaded into RAM if it is not there.
''      It will be mightly slow in SPIN, so I added a 'preload macro' to FVM so that
''      a user/compiler can avoid the loading overhead when they call the macro for
''      time sensitive situations. I'll work on implementing assembly later.
''    - A sixth COG will run Bottle Rocket and be responsible for updating addressable
''      strips as the memory array is updated. Communication between Bottle Rocket and
''      FVM still needs to be worked out.
''
''    - I also added opcodes for 'wait signal' and 'post signal' so the user can communicate
''      with an already running macro. I think WAITS 0 will be wait for any non-zero signal.
''      Also, POSTS FF will be a termination signal. WAITS FF is just waiting for termination
''      which is essentially a delayed RETMC and POSTS 0 is just posting no signal, so it is
''      essentially a NOP. All other signals are free to use.
''
'' Macro memory structure -
''    - For each macro in RAM, there are five leading bytes that are of special use.
''    - The first two bytes is for allocation. The leading bit is whether or not that
''      memory location is in use. The remaining 15-bits are the length of the allocated
''      space if the leading bit is set to 1.
''    - The remaining 3 bytes are for macro use. When a macro is called from a macro
''      the macro number of the caller is placed in the first of the three bytes of the callee.
''      The next two bytes are for the callers program pointer. (the program pointer is of the
''      code section of the macro. Which means PC=0 is PC=macro_base+5)
''
'' What needs to be done -
''    - Separate input and macro interpreter versions of FVM
''    - Create a test with another board to test SPI
''    - Write I2C com
''    - Finish writing the MM
''    - Fill in missing opcodes (pretty much everything macro related)
''    - everything involving Bottle Rocket
''    - correct macro processing to account for memory structure
''      with the new limits of approximately 160 LEDs and 
''       
'''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''

CON

  FVM_DEFAULT_WA_SIZE     = 8192   ' macro work area                        
  FVM_DEFAULT_NUM_MACROS  = 256  
  FVM_DEFAULT_STACK_SIZE  = 256
  FVM_DEFAULT_BUFFER_SIZE = 256
  FVM_DEFAULT_NUM_OUTPUTS = 16

  FVM_OUTPUT_MASK = $FFFF0000

  FVM_NOP_OPCODE   = 0                                                          ' both
  FVM_PUSH_OPCODE  = 1                                                          ' both
  FVM_POP_OPCODE   = 2                                                          ' both
  FVM_WRITE_OPCODE = 3                                                          ' both
  FVM_DELAY_OPCODE = 4                                                          ' both
  FVM_INC_OPCODE   = 5                                                          ' both
  FVM_DEC_OPCODE   = 6                                                          ' both 
  FVM_ADD_OPCODE   = 7                                                          ' both
  FVM_SUB_OPCODE   = 8                                                          ' both
  FVM_CMP_OPCODE   = 9                                                          ' macro only
  FVM_OR_OPCODE    = 10                                                         ' both
  FVM_AND_OPCODE   = 11                                                         ' both
  FVM_TEST_OPCODE  = 12                                                         ' macro only
  FVM_NOT_OPCODE   = 13                                                         ' both
  FVM_SWAP_OPCODE  = 14                                                         ' both
  FVM_DUP_OPCODE   = 15                                                         ' both
  FVM_IF_OPCODE    = 16                                                         ' macro only
  FVM_JUMP_OPCODE  = 17         ' jump                                          ' macro only
  FVM_JMPR_OPCODE  = 18         ' jump relative                                 ' macro only
  FVM_DEFMC_OPCODE = 19         ' define macro                                  ' both
  FVM_CALMC_OPCODE = 20         ' call macro                                    ' both (different implementations)
  FVM_RETMC_OPCODE = 21         ' return from macro                             ' macro only
  FVM_DLAYM_OPCODE = 22         ' delay microseconds                            ' both
  FVM_SAVMC_OPCODE = 23         ' save macro                                    ' both
  FVM_DELMC_OPCODE = 24         ' delete macro                                  ' both
  FVM_LDMC_OPCODE  = 25         ' preload macro                                 ' both
  FVM_WAITS_OPCODE = 26         ' wait for signal                               ' both
  FVM_POSTS_OPCODE = 27         ' post signal                                   ' both

  MM_LOAD_MACRO    = 1
  MM_SAVE_MACRO    = 2
  MM_DEL_MACRO     = 4



OBJ

  eeprom  :  "Propeller Eeprom"
                                    
VAR

  long FVM_PWM_table[FVM_DEFAULT_NUM_OUTPUTS] ' PWM outputs

  long FVM_macros[FVM_DEFAULT_NUM_MACROS]     ' macro table (first two bytes is EEPROM address and last two bytes are RAM address)

  byte FVM_buffer[FVM_DEFAULT_BUFFER_SIZE]    ' input buffer

  byte FVM_data_stack[FVM_DEFAULT_STACK_SIZE] ' Data stack that operations are performed on

  byte FVM_buffer_index                       ' index of buffer filled

  byte FVM_manager_request                    ' indicates request for macro manager
  
  byte FVM_manager_request_addr               ' the macro number requested for operation

  byte FVM_signal                             ' signal line
  
  byte FVM_macro_space[FVM_DEFAULT_WA_SIZE]   ' memory allocated for macro(s) being executed
  
PUB Start | n

  dira := $0000_FFFF | spi_misomask | i2c_sdamask       ' configure outputs for our purposes

  cognew(@recv_entry, @FVM_buffer)

  cognew(@hires, @FVM_PWM_table)

  pwm_base   := @FVM_PWM_table
  buf_base   := @FVM_buffer
  stack_base := @FVM_data_stack
  bufin_ptr  := @FVM_buffer_index
  macro_base := @FVM_macros
  
  cognew(@fvm_entry, 0)
  
  repeat n from 0 to 52 step 4                          ' patch job
    long[@fvm_getdata+n] := long[@fvm_macro_patch+n]

  cognew(@fvm_entry, 0)                                 ' start new macro version

PUB MacroManager | address, s, len1, len2, end

  repeat while (true)
  
    repeat while (!FVM_manager_request)    ' wait for a macro request

    if (FVM_manager_request == MM_LOAD_MACRO)           ' request to load macro
    
      address := FVM_macros[FVM_manager_request_addr]   ' find entry
       
      if (address & $FFFF)                              ' if it has a valid address in RAM then don't worry
        FVM_manager_request := 0                        ' notify                        
        next

      if (!address)
        FVM_manager_request := -1                       ' notify that macro is undefined
        waitcnt(8000 + cnt)                             ' wait
        FVM_manager_request := 0                        ' clear error
        next

      address >>=  16                                   ' get EEPROM address

      eeprom.ToRam(@len1, @len1+1,address)              ' read descriptor (alloc bit and 15-bit length)

      if (!(len1 & $10000))                             ' ensure it's allocated in EEPROM
        FVM_manager_request := -1
        waitcnt(8000 + cnt)
        FVM_manager_request := 0
        next

      len1 &= $FFFF                                     ' extract length

      s    := @FVM_macros                               ' selected RAM address

      end  := @FVM_macros + FVM_DEFAULT_WA_SIZE         ' end address

      len2 := word[s]                                   ' length of RAM block

      repeat while (len2 and (s < end))                 ' search for empty RAM block 
        s += len2 + 1
        len2 := word[s] 

      if (!len2 and ((end - s) => len1))
        eeprom.ToRam(s, s+len1, address)
        FVM_manager_request := 0
        next
      
    elseif (FVM_manager_request == MM_SAVE_MACRO)
    elseif (FVM_manager_request == MM_DEL_MACRO)
    
    else
      next
           

DAT FireCrackerVM

'''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''
''
''   FVM_entry -
''      Start the Firecracker VM 
''
'''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''
                        org     0
fvm_entry_inp

fvm_process_inp
''
'' All macros take arguments from the stack except for stack
'' operations themselves. Stack operations get their arguments
'' (things like length and data) from the data input (either buffer
'' or macro).
''
''
                        mov     stack_ptr, stack_base
                        add     stack_ptr, stack_ind
                        mov     G1, #1                        ' get opcode address 
                        call    #fvm_getdata
                        rdbyte  opcode, G0                    ' read opcode
                        
fvm_eval_opcode_inp
                        mov     G1, #fvm_opcode_table         ' load G1 with opcode table address
                        add     G1, opcode                    ' add opcode offset

                        jmp     G1                            ' jump to correct index into jump table
fvm_opcode_table_inp                                          ' HUB access is aligned on first instruction upon entering each table entry
                        jmp     #fvm_nop                      ' Y
                        jmp     #fvm_push                     ' Y 
                        jmp     #fvm_pop                      ' Y 
                        jmp     #fvm_write                    ' Y 
                        jmp     #fvm_delay                    ' Y 
                        jmp     #fvm_inc                      ' Y 
                        jmp     #fvm_dec                      ' Y 
                        jmp     #fvm_add                      ' Y 
                        jmp     #fvm_sub                      ' Y 
                        jmp     #fvm_cmp                      ' N
                        jmp     #fvm_or                       ' Y 
                        jmp     #fvm_and                      ' Y 
                        jmp     #fvm_test                     ' N
                        jmp     #fvm_not                      ' Y 
                        jmp     #fvm_swap                     ' Y 
                        jmp     #fvm_dup                      ' Y 
                        jmp     #fvm_if                       ' N
                        jmp     #fvm_jmp                      ' N
                        jmp     #fvm_defmc                    ' Y 
                        jmp     #fvm_calmc                    ' Y 
                        jmp     #fvm_dlaym                    ' Y 
                        jmp     #fvm_savmc                    ' Y 
                        jmp     #fvm_delmc                    ' Y 
                        jmp     #fvm_ldmc                     ' Y 
                        jmp     #fvm_waits                    ' Y 
                        jmp     #fvm_posts                    ' Y 

fvm_nop
''
'' FVM_NOP macro does absolutely nothing but waste time and space.
'' 
''   
                        add     count, #1
                        jmp     #fvm_end_processing

fvm_push
''
'' FVM_PUSH macro is followed by a length byte specifying how many
'' bytes that follow are to be pushed to the stack. The macro takes
'' a minimum of two bytes
''
''   
                        mov     G1, #2                        ' add push opcode and length byte
                        call    #fvm_getdata                  ' ensure data is available
                        add     G0, #1                        ' go to length byte
                        nop
                        nop
                        nop
                        rdbyte  G1, G0                        ' read length into G1 
                        
                        add     G1, #2                        ' add push opcode and length byte
                        call    #fvm_getdata                  ' ensure data is available
                        add     G0, #2                        ' go to data in buffer
                        add     count, G1                     ' update count of processed bytes
                        sub     G1, #2                  wz    ' adjust G1 to data length
                        mov     G2, stack_base                ' load stack pointer
                        
                        add     G2, stack_ind                 ' add stack index
                        add     stack_ind, G1                 ' update stack index
                        and     stack_ind, #$FF               ' cap at 8 bits
              if_z      jmp     #fvm_end_processing           ' return if length is zero

fvm_push_00
                        nop
                        rdbyte  G3, G0                        ' read next byte
                        sub     G1, #1                  wz    ' decrement counter
                        add     G0, #1                        ' increment data buffer pointer
                        wrbyte  G3, G2                        ' store in stack
                        add     G2, #1                        ' go to next stack value
              if_nz     jmp     #fvm_push_00                  ' reloop for data length 

                        jmp     #fvm_end_processing           ' exit
                        
fvm_pop
''
'' FVM_POP macro is followed by a length byte and specifies
'' how many bytes are popped from the stack. The pop simply decrements
'' the stack pointer by the length field.
''
''   
                        mov     G1, #2                        ' ensure we have a length byte present
                        call    #fvm_getdata                  ' ^
                        add     G0, #1                        ' go to length byte
                        add     count, #2                     ' increment by 2
                        nop
                        nop
                        rdbyte  G0, G0                        ' read length into G0
                        sub     stack_ind, G0                 ' subtract our index to pop
                        and     stack_ind, #$FF               ' cap at 8 bits
                        jmp     #fvm_end_processing           ' exit
                        
                        
fvm_write
''
'' FVM_WRITE macro takes a 1 byte pin address and a 1 byte value.
'' It writes the 8-bit PWM value to any of the lower 16 pins
'' (pins 0-15). The PWM signal generated is not fixed duty cycle.
''
''
                        rdbyte  G1, stack_ptr                        ' read pin number
                        mov     G2, pwm_base                  ' load pwm base
                        add     G0, #1                        ' go to value
                        rdbyte  G3, G0                        ' read value into G3
                        and     G1, #$0F                      ' cap at 4 bits (16 pins)
                        shl     G1, #2                        ' multiply by 4

                        add     G2, G1                        ' go to offset in PWM table
                        shl     G3, #24                       ' convert to 32-bit value for processing
                        and     G1, write_mask                ' set all lower bits to 1 
                        sub     stack_ind, #2                 ' decrement stack
                        wrlong  G3, G2                        ' store value in table
                        add     count, #1                     ' add to count
                        and     stack_ind, #$FF
                        jmp     #fvm_end_processing           ' exit

write_mask    long      $00FF_FFFF                         
                        
fvm_delay
''
'' FVM_DELAY macro takes an unsigned 32-bit integer in nano-seconds.
'' of course, we are only running at 80 MHz so doing nano-seconds is tough.
'' the function waits a minimum of 1300 ns, and has a resolution of 100 ns
''
''
                        rdbyte  G1, stack_ptr                 ' read byte
                        shl     G1, #24                       ' shift up
                        add     stack_ptr, #1                 ' go to next byte
                        rdbyte  G2, stack_ptr                 ' read byte
                        shl     G2, #16                       ' shift up
                        add     stack_ptr, #1                 ' go to next byte
                        rdbyte  G3, stack_ptr                 ' read byte
                        shl     G3, #8                        ' shift up
                        add     stack_ptr, #1                 ' go to next byte
                        rdbyte  G4, stack_ptr                 ' read byte
                        or      G4, G3
                        or      G4, G2
                        or      G4, G1                        ' construct number in G4

                        sub     G4, num1300             wz,wc ' adjust remaining time
              if_be     jmp     #fvm_delay_01                 ' if time is not positive, we leave
fvm_delay_00
                        sub     G4, #100                wz,wc ' 100ns per loop
              if_a      jmp     #fvm_delay_00                 ' reloop
fvm_delay_01
                        sub     stack_ind, #4                 ' subtract four bytes
                        and     stack_ind, #$FF               ' cap at four bits
                        add     count, #1                
                        jmp     #fvm_end_processing                                       
                                                         
fvm_inc
''
'' FVM_INC macro simply takes the byte on the top of the stack
'' and increments it by 1.
''
''
                         rdbyte G0, G1                        ' load byte
                         add    G0, #1                        ' increment
                         add    count,#1
                         wrbyte G0, G1                        ' store

                         jmp    #fvm_end_processing           ' exit

fvm_dec
''
'' FVM_DEC macro simply takes the byte on the top of the stack
'' and decrements it by 1.
''
''
                         rdbyte G0, G1                        ' load byte
                         sub    G0, #1                        ' increment
                         add    count,#1
                         wrbyte G0, G1                        ' store

                         jmp    #fvm_end_processing           ' exit

fvm_add             
''
'' FVM_ADD macro pops the top two bytes on the stack, adds them
'' and finally pushes the sum back to the stack
''
''
                        rdbyte  G0, stack_ptr
                        sub     stack_ptr, #1
                        sub     stack_ind, #1
                        rdbyte  G1, stack_ptr
                        add     G0, G1
                        and     stack_ind, #$FF
                        wrbyte  G0, stack_ptr

                        add     count,#1
                        jmp     #fvm_end_processing
fvm_sub
''
'' FVM_SUB macro pops the top two bytes on the stack, subtracts
'' the first item pushed to the stack, from the second or
'' the (top) - (top - 1), and pushes the result back
'' to the stack
''
''
                        rdbyte  G0, stack_ptr
                        sub     stack_ptr, #1
                        sub     stack_ind, #1
                        rdbyte  G1, stack_ptr
                        sub     G0, G1
                        and     stack_ind, #$FF
                        wrbyte  G0, stack_ptr
                        
                        jmp     #fvm_end_processing
                                                
fvm_cmp
fvm_or
fvm_and
fvm_test
fvm_not
fvm_swap
fvm_dup
                        mov     G1, #2
                        call    #fvm_getdata
                        
                        add     G0, #1                        ' go to length count byte
                        mov     G2, stack_base                ' load stack base to G2
                        add     G2, stack_ind                 ' add stack index
                        mov     G3, G2                        ' copy to G3; one pointer goes up, the other goes down
                        
                        rdbyte  G1, G0                  wz    ' read length of data and test for zero

                        sub     G2, G1                        ' go to lowest data
              if_z      jmp     #fvm_end_processing           ' exit

fvm_dup_00
                        rdbyte  G0, G2                        ' read byte
                        add     G2, #1                        ' go to next byte to copy
                        sub     G1, #1                  wz    ' decrement counter
                        wrbyte  G0, G3                        ' write byte in upper area
                        add     G3, #1                        ' go to next write location
              if_nz     jmp     #fvm_dup_00                   ' reloop

                        jmp     #fvm_end_processing

                        
fvm_if
fvm_jmp
fvm_defmc

fvm_calmc
fvm_retmc
fvm_dlaym

''
'' FVM_DLAYM macro takes an unsigned 32-bit integer in micro-seconds.
'' minimum wait time of 1.2us for 0 and 1us specified. All other values
'' delay precisely.
''
''                       
                        mov     G0, stack_base                ' stack base
                        add     G0, stack_ind                 ' go to stack pointer
                        nop
                        nop                                   ' read byte by byte to avoid alignment issues
                        rdbyte  G1, G0                        ' read byte
                        shl     G1, #24                       ' shift up
                        add     G0, #1                        ' go to next byte
                        rdbyte  G2, G0                        ' read byte
                        shl     G2, #16                       ' shift up
                        add     G0, #1                        ' go to next byte
                        rdbyte  G3, G0                        ' read byte
                        shl     G3, #8                        ' shift up
                        add     G0, #1                        ' go to next byte
                        rdbyte  G4, G0                        ' read byte
                        or      G4, G3
                        or      G4, G2
                        or      G4, G1                        ' construct number in G4

                        sub     G4, #2                  wz,wc ' adjust remaining time
              if_b      jmp     #fvm_dlaym_03                 ' if time is not positive, we leave
fvm_dlaym_00            
                        mov     G3,#8 
fvm_dlaym_01
                        sub     G3, #1                  wz
              if_nz     jmp     #fvm_dlaym_01

                        sub     G4, #1                  wz,wc ' subtract
              if_a      jmp     #fvm_dlaym_00                 ' reloop

                        mov     G3,#14 
fvm_dlaym_02
                        sub     G3, #1                  wz,wc
              if_a      jmp     #fvm_dlaym_02
                        jmp     #fvm_end_processing

fvm_dlaym_03
                        mov     G3,14
              if_ae     jmp     #fvm_dlaym_02 
                        jmp     #fvm_end_processing           ' leave

fvm_savmc
fvm_delmc
fvm_ldmc
fvm_waits
fvm_posts   


fvm_getdata             ' gets data from either buffer or macro area

'' FVM_getdata -
''    G1 should contain length of data requested upon entry
''    G0 will contain the address of first byte if data is available
''    All G2-G4 will be FUBAR
''
''    HUB access is available immidiately upon return from FVM_getdata
''
                                                              ' N - get data from buffer
                        rdbyte  G0, bufin_ptr                 ' load filled index

                        mov     G7, G0                        ' load G7 with filled index
                        sub     G7, buf_proc                  ' subtract index to get length available
                        
                        cmp     G7, G1                  wz,wc ' ? length available >= length requested
              if_b      jmp     #fvm_end_processing           ' N - wait for more data
                        mov     G0, buf_base                  ' load G0 with buffer pointer
                        add     G0, buf_proc                  ' go to next process index
                        
                        jmp     #fvm_getdata_ret              ' exit
                        nop
                        nop
                        nop
                        nop
                        nop
                        nop

fvm_getdata_ret   
              if_ae     ret                                   '    
                        jmp     #fvm_err_processing           ' N - end processing with error


fvm_err_processing                                                                 
fvm_end_processing
                        or      macro, macro            wz
              if_z      jmp     #fvm_end_processing_00        ' if no macro address, it's through the buffer

                        add     macro, count                  ' otherwise add to macro address
                        xor     count, count                  ' zero count 
                        jmp     #fvm_process                  ' reloop   
                          
fvm_end_processing_00
                        add     buf_proc, count               ' if not in a macro, add count to buffer processed index
                        and     buf_proc, #$FF                ' cap at 8 bits
                        xor     count, count                  ' zero count

                        jmp     #fvm_process                  ' reloop
                        
                                                                                                                      

num1300       long      1300                                                       
num512        long      512
'
' experimental delay using counter and waitpeq
'
' main issue is that each clock is 12.5 ns, so we can't really subtract
' 12.5 ns and there is no way to accumulate the .5 without going to
' 25 ns resolution. And at that rate I may as well
' wait the 100 ns with no counter. 
' 
delay_ctr     long      %0_00100_000_00000000_000000_000_010000   ' use pin 16 for NCO, reads into pin 17

pwm_base      long      1       ' PWM table   
macro_base    long      1       ' start of macro address table
buf_base      long      1       ' buffer ptr
stack_base    long      1       ' start of data stack 
bufin_ptr     long      1       ' buffer index pointer

''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''
' general registers
G0            res       1
G1            res       1
G2            res       1
G3            res       1
G4            res       1
G5            res       1
G6            res       1
G7            res       1          
'
''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''
opcode        res       1       ' current opcode processed
count         res       1       ' number of bytes processed
buf_proc      res       1       ' index of buffer processed
flags         res       1       ' internal VM flags
stack_ind     res       1       ' current index in stack
stack_ptr     res       1       ' calculated at the start of each process
macro         res       1       ' start of macro
macno         res       1       ' length of macro

                        FIT

DAT FVMMacroPatch

fvm_macro_patch
                        mov     G2, macno                     ' move in macro number
                        shl     G2, #2                        ' multiply by 4
                        add     G2, macro_base                ' add base address of table
                        rdbyte  G3, G2                        ' read in first byte
                        shl     G3, #8                        ' free lower 8 bits
                        add     G2, #1                        ' point to next byte
                        rdbyte  G4, G2                        ' get next byte
                        mov     G2, macno                     ' load macro number
                        add     G2, macro_base                ' point to length of macro
                        rdbyte  G0, G2                        ' read length into G0
                        or      G4, G3                        ' form full word of macro address in G4 
                        add     G1, macro                     ' get end of data in G1
                        
                        add     G4, G0                        ' get end of macro in G4
                        cmp     G4, G3                  wc,wz ' ? macro end >= data end
              if_ae     mov     G0, macro                     ' Y - return macro address


CON
''
'' FireCracker SPI reciever -
''      


  spi_clk  = 18                 ' clock pin             
  spi_mosi = 19                 ' master out / slave in
  spi_miso = 20                 ' master in / slave out
  spi_cs   = 21                 ' chip select
  i2c_sda  = 16                 ' I2C data pin
  i2c_scl  = 17                 ' I2C clock pin

DAT StartRecv

                        org     0
recv_entry
                        or      dira,#(1<<0)
                        or      outa,#(1<<0)
                        mov     buf_addr,par
                        mov     buf_ind, buf_addr
                        add     buf_ind, #256
                        add     buf_ind, #256
                        add     buf_ind, #256
                        mov     phsa,#0
                        mov     phsb,#0
                        mov     frqa,#1
                        mov     frqb,#1
                        mov     ctra,recv_spicntl
                        mov     ctrb,recv_i2ccntl
                        or      dira,spi_clkmask
                        or      outa,spi_clkmask
recv_entry00
                        or      phsa, phsb              wz,nr ' ? either pin gets a positive edge                     
              if_z      jmp     #recv_entry00                 ' N - reloop if neither pin set

                        andn    outa,spi_clkmask
                        cmp     ina, spi_mosimask       wz    ' ? SPI set
              if_z      jmp     #spi_entry                    ' Y - go to SPI

                        cmp     ina, i2c_sclmask              ' ? I2C set
              if_z      jmp     #i2c_entry                    ' Y - go to I2C

                        mov     dira, recv_errmask            ' move in error mask
                        mov     outa, recv_errmask            ' drive all lines high
                        cogid   zero
                        cogstop zero                          ' kill service

spi_entry
                        or      dira, spi_misomask            ' configure pin(s) for output

                        mov     frqa,#1
                        mov     frqb,#1                       '
                        mov     phsa,#0
                        mov     phsb,#0
                        mov     ctra,spi_clkcntl              ' wait for pins to both be low
                        movs    ctra,#spi_clk
                        movd    ctra,#spi_cs                  ' monitor cs and clk pins
                        mov     ctrb,spi_datcntl
                        movs    ctrb,#spi_mosi
                        mov     spi_count, #8

                        or      outa, spi_misomask
                        waitpeq zero, spi_mosimask

''
'' Maximum data rate of 2Mb/s (256KB/s)
'' 
'' right now, capable speed is between 1.94Mb/s and 2.16Mb/s
'' which is between 248KB/s and 276KB/s. I would cap it
'' at 2Mb/s because going any faster requires sharp timing
'' between the master and when this COG has HUB access
'' which is a completely unreasonable thing to account for.
''
'' Those speeds is the max data rate range. This is a synchronous
'' protocol, so going slower will work fine. Just don't go over
'' 2Mb/s.
''
spi_waitloop
                        tjz     phsa,#spi_waitloop            ' wait for both pins to be low
spi_waitloop00
                        shl     phsb,#1                       ' shift data in over
                        mov     phsa,#0                       ' zero event
                        waitpeq one, spi_clkmask              ' wait for raised clock
                        djnz    spi_count, #spi_waitloop      ' reloop if we do not have 8 bits

                        rdbyte  temp, buf_ind
                        add     temp, buf_addr
                        mov     spi_count, #8
                        wrbyte  phsb, temp
                        sub     temp, buf_addr
                        add     temp, #1
                        wrbyte  temp, buf_ind
                        jmp     #spi_waitloop
                        
                                    
                                  
i2c_entry
                                   

zero          long      0
one           long      1

recv_spicntl  long      %01010_000_00000000_000000_000_000000 | spi_mosi
recv_i2ccntl  long      %01010_000_00000000_000000_000_000000 | i2c_scl
recv_mask     long      spi_mosimask | i2c_sclmask
recv_errmask  long      spi_misomask | i2c_sdamask

spi_clkcntl   long      %10001_000_00000000_000000_000_000000
spi_datcntl   long      %01010_000_00000000_000000_000_000000
spi_clkmask   long      1 << spi_clk
spi_mosimask  long      1 << spi_mosi
spi_misomask  long      1 << spi_miso
spi_csmask    long      1 << spi_cs

i2c_sdamask   long      1 << i2c_sda
i2c_sclmask   long      1 << i2c_scl
spi_mode      long      0

temp          res       1
buf_addr      res       1
buf_ind       res       1
spi_count     res       1

              FIT

DAT PWMHandler

'''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''
''
''   hires - PWM driver 
''   Code copied from PropPWM and modified for 16 outputs instead of all 32
''   allows for easier management of memory, as well as half the memory use
''
''
'''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''

' 32-bit PWM with 294.12 kHz switching frequency (94% faster than 32 pins)
' Method uses the carry flag to proportion the on-time of the duty cycles
' Each cycle, the duty cycle of the pin is added to a counter for that
' pin. When this generates a carry, the pin is set to high, otherwise it is low.
' This means the a true duty cycle, that accurately represents the value of the
' signal takes whatever number of cycles it takes to accurately represent that
' the value in fractional form.


                        org     0
hires
                        mov     pinTableBase,par             ' Move in the HUBRAM address of the pin values table
                        mov     counter,#16                  ' Counter used to generate the table of pin HUBRAM addresses
                        mov     dutyReg,#pinAddress00
                        
' Initializes a table containing the HUBRAM address of every pin
' in order to avoid having to increment a reference address each
' time we have to access the table, thus increasing speed.

setup
                        movd    tableEntry, dutyReg
                        add     dutyReg,#1 
tableEntry                                   
                        add     0000,pinTableBase 
                        djnz    counter, #setup
                        
dutyStart               
                        rdlong  dutyReg,pinAddress00         ' Read the value of the zero-th pin into the dutyReg
                        add     dutyTable00,dutyReg       wc   ' Add to the accumulator
              if_c      or      buffer,pinMask00             ' If a carry was generated, set the pin to high
              
                        rdlong  dutyReg,pinAddress01         ' repeat this process, each time going to the next pin, and next 
                        add     dutyTable01,dutyReg       wc
              if_c      or      buffer,pinMask01 

                        rdlong  dutyReg,pinAddress02         ' This goes on 16 times. Once per pin.
                        add     dutyTable02,dutyReg       wc
              if_c      or      buffer,pinMask02 

                        rdlong  dutyReg,pinAddress03
                        add     dutyTable03,dutyReg       wc
              if_c      or      buffer,pinMask03 

                        rdlong  dutyReg,pinAddress04
                        add     dutyTable04,dutyReg       wc
              if_c      or      buffer,pinMask04 

                        rdlong  dutyReg,pinAddress05
                        add     dutyTable05,dutyReg       wc
              if_c      or      buffer,pinMask05 

                        rdlong  dutyReg,pinAddress06
                        add     dutyTable06,dutyReg       wc
              if_c      or      buffer,pinMask06 

                        rdlong  dutyReg,pinAddress07
                        add     dutyTable07,dutyReg       wc
              if_c      or      buffer,pinMask07 

                        rdlong  dutyReg,pinAddress08
                        add     dutyTable08,dutyReg       wc
              if_c      or      buffer,pinMask08 

                        rdlong  dutyReg,pinAddress09
                        add     dutyTable09,dutyReg       wc
              if_c      or      buffer,pinMask09 

                        rdlong  dutyReg,pinAddress0A
                        add     dutyTable0A,dutyReg       wc
              if_c      or      buffer,pinMask0A 

                        rdlong  dutyReg,pinAddress0B
                        add     dutyTable0B,dutyReg       wc
              if_c      or      buffer,pinMask0B 

                        rdlong  dutyReg,pinAddress0C
                        add     dutyTable0C,dutyReg       wc
              if_c      or      buffer,pinMask0C 

                        rdlong  dutyReg,pinAddress0D
                        add     dutyTable0D,dutyReg       wc
              if_c      or      buffer,pinMask0D 

                        rdlong  dutyReg,pinAddress0E
                        add     dutyTable0E,dutyReg       wc
              if_c      or      buffer,pinMask0E 

                        rdlong  dutyReg,pinAddress0F
                        add     dutyTable0F,dutyReg       wc
              if_c      or      buffer,pinMask0F 

                        mov     dira,buffer                     ' Set those pins to output                       
                        mov     outa,buffer                     ' Write high to the pins set      
                        xor     buffer,buffer                   ' Clear buffer for next cycle
                        jmp     #dutyStart                      ' Go to next cycle

' Pin mask table used to set pins                        
pinMask00     long      %0000_0000_0000_0000_0000_0000_0000_0001
pinMask01     long      %0000_0000_0000_0000_0000_0000_0000_0010
pinMask02     long      %0000_0000_0000_0000_0000_0000_0000_0100
pinMask03     long      %0000_0000_0000_0000_0000_0000_0000_1000
pinMask04     long      %0000_0000_0000_0000_0000_0000_0001_0000
pinMask05     long      %0000_0000_0000_0000_0000_0000_0010_0000
pinMask06     long      %0000_0000_0000_0000_0000_0000_0100_0000
pinMask07     long      %0000_0000_0000_0000_0000_0000_1000_0000
pinMask08     long      %0000_0000_0000_0000_0000_0001_0000_0000
pinMask09     long      %0000_0000_0000_0000_0000_0010_0000_0000
pinMask0A     long      %0000_0000_0000_0000_0000_0100_0000_0000
pinMask0B     long      %0000_0000_0000_0000_0000_1000_0000_0000
pinMask0C     long      %0000_0000_0000_0000_0001_0000_0000_0000
pinMask0D     long      %0000_0000_0000_0000_0010_0000_0000_0000
pinMask0E     long      %0000_0000_0000_0000_0100_0000_0000_0000
pinMask0F     long      %0000_0000_0000_0000_1000_0000_0000_0000

pinAddress00     long      0
pinAddress01     long      4
pinAddress02     long      8
pinAddress03     long      12
pinAddress04     long      16
pinAddress05     long      20
pinAddress06     long      24
pinAddress07     long      28
pinAddress08     long      32
pinAddress09     long      36
pinAddress0A     long      40
pinAddress0B     long      44
pinAddress0C     long      48
pinAddress0D     long      52
pinAddress0E     long      56
pinAddress0F     long      60

dutyTable00     long      0
dutyTable01     long      0
dutyTable02     long      0
dutyTable03     long      0
dutyTable04     long      0
dutyTable05     long      0
dutyTable06     long      0
dutyTable07     long      0
dutyTable08     long      0
dutyTable09     long      0
dutyTable0A     long      0
dutyTable0B     long      0
dutyTable0C     long      0
dutyTable0D     long      0
dutyTable0E     long      0
dutyTable0F     long      0

dutyReg       res       1    ' Register that duty cycle gets read into
counter       res       1    ' Counter for generating the address table
pinTableBase  res       1    ' HUBRAM address of pin addresses
buffer        res       1    ' Bitmask buffer    
                        FIT
                        
; =============================================================================
; conv2d_x87.asm  -  Implementacion (win32, cdecl)
; =============================================================================
;
; RECURSO: 
; - https://linasm.sourceforge.net/docs/instructions/fpu.php
; - https://www.felixcloutier.com/x86/
; Expone los dos simbolos que benchmark.c necesita:
;   _conv2d_impl  funcion      -- convolucion 2D completa
;
;
; CONVENCION DE LLAMADA cdecl x86 (32 bits)
; ------------------------------------------
; - Parametros en pila, derecha a izquierda, antes del CALL.
; - El LLAMADOR limpia la pila tras el retorno.
; - Registros NO volatiles (deben preservarse): 
;      - EBX, ESI, EDI, EBP.
; - Registros VOLATILES (pueden destruirse): 
;      - EAX, ECX, EDX.
;
; MAPA DE PILA tras prólogo:
; ------------------------------------------
;   [ebp +  0] = ebp guardado
;   [ebp +  4] = direccion de retorno
;   [ebp +  8] = in      (const float*)
;   [ebp + 12] = out     (float*)
;   [ebp + 16] = width   (int)
;   [ebp + 20] = height  (int)
;   [ebp + 24] = kernel  (puntero a float[3][3])
;
; VARIABLES LOCALES:
; Se reserva espacio en el prologo para estos 4 enteros con sub esp, 16
; ------------------------------------------
;   [ebp -  4] = row_stride  width * 4  (bytes por fila)
;   [ebp -  8] = j_limit     height - 1 (limite bucle j)
;   [ebp - 12] = i_limit     width  - 1 (limite bucle i)
;   [ebp - 16] = j           indice del bucle exterior
;
;
; ASIGNACION DE REGISTROS (bucle interior)
; -----------------------------------------
;   EBX  = puntero a fila j-1 (row0), columna i-1  [no-volatil]
;   ESI  = puntero a fila j   (row1), columna i-1  [no-volatil]
;   EDI  = puntero a fila j+1 (row2), columna i-1  [no-volatil]
;   EDX  = puntero de escritura en out, columna i  [volatil, ok]
;   ECX  = indice i del bucle interior             [volatil, ok]
;   EAX  = puntero base del kernel                 [volatil, ok]
;
; Los registros volatiles EAX/ECX/EDX no necesitan preservarse porque
; se recalculan en cada iteracion del bucle exterior.
;
; CALCULO DE DIRECCIONES
; -----------------------
; Para cada fila j, los punteros de fila se calculan una vez con IMUL:
;   row0 = in  + (j-1) * row_stride     [columna 0]
;   row1 = in  +  j    * row_stride     [columna 0]
;   row2 = in  + (j+1) * row_stride     [columna 0]
;   outp = out +  j    * row_stride + 4 [columna 1]
;
; En el bucle interior cada puntero avanza 4 bytes por iteracion
; (un float), sin necesidad de recalcular offsets.
;
; ACCESO AL KERNEL
; ----------------
; El kernel float[3][3] es contiguo en memoria (row-major):
;   [eax +  0] = kernel[0][0]   [eax + 12] = kernel[1][0]   [eax + 24] = kernel[2][0]
;   [eax +  4] = kernel[0][1]   [eax + 16] = kernel[1][1]   [eax + 28] = kernel[2][1]
;   [eax +  8] = kernel[0][2]   [eax + 20] = kernel[1][2]   [eax + 32] = kernel[2][2]
;
; PATRON MAC x87
; ---------------
;   fldz              -> ST0 = 0.0  (acumulador inicial)
;   fld  dword [pixel]-> apila pixel; ST0=pixel, ST1=acc
;   fmul dword [coef] -> ST0 = pixel * coef
;   faddp st1, st0    -> ST0 = acc + producto (con pop automatico)
; Al final: fstp dword [edx] almacena y vacia la pila FPU.
; =============================================================================

bits 32

section .text
global _conv2d_impl

_conv2d_impl:
    ; ---- Prologo cdecl ----
    push    ebp
    mov     ebp, esp
    sub     esp, 16             ; reservar 4 variables locales
    push    ebx                 ; no-volatil
    push    esi                 ; no-volatil
    push    edi                 ; no-volatil

    ; ---- Precomputar constantes ----

    ; row_stride = width * 4
    mov     eax, [ebp + 16]     ; eax = width
    shl     eax, 2              ; eax = width * 4
    mov     [ebp - 4], eax      ; local: row_stride

    ; j_limit = height - 1  (bucle: j < j_limit, es decir j <= height-2)
    mov     eax, [ebp + 20]     ; eax = height
    dec     eax
    mov     [ebp - 8], eax      ; local: j_limit

    ; i_limit = width - 1   (bucle: i < i_limit, es decir i <= width-2)
    mov     eax, [ebp + 16]     ; eax = width
    dec     eax
    mov     [ebp - 12], eax     ; local: i_limit

    ; j = 1  (inicio del bucle exterior)
    mov     dword [ebp - 16], 1

; ---- Bucle exterior: for (j = 1; j < height-1; j++) ----
.outer:
    mov     eax, [ebp - 16]     ; eax = j
    cmp     eax, [ebp - 8]      ; j < j_limit ?
    jge     .done

    ; Calcular punteros de fila usando IMUL (no modifica EDX al contrario de MUL)
    mov     ecx, [ebp - 4]      ; ecx = row_stride (temporal para los IMUL)

    ; EBX = in + (j-1) * row_stride
    mov     eax, [ebp - 16]
    dec     eax                 ; j - 1
    imul    eax, ecx            ; (j-1) * stride
    add     eax, [ebp + 8]      ; + in
    mov     ebx, eax            ; EBX = row0, columna 0

    ; ESI = in + j * row_stride
    mov     eax, [ebp - 16]
    imul    eax, ecx            ; j * stride
    add     eax, [ebp + 8]      ; + in
    mov     esi, eax            ; ESI = row1, columna 0

    ; EDI = in + (j+1) * row_stride
    mov     eax, [ebp - 16]
    inc     eax                 ; j + 1
    imul    eax, ecx            ; (j+1) * stride
    add     eax, [ebp + 8]      ; + in
    mov     edi, eax            ; EDI = row2, columna 0

    ; EDX = out + j * row_stride + 4  (columna i=1)
    mov     eax, [ebp - 16]
    imul    eax, ecx            ; j * stride
    add     eax, [ebp + 12]     ; + out
    add     eax, 4              ; columna 1 (saltar borde izquierdo)
    mov     edx, eax            ; EDX = puntero de salida

    ; EAX = puntero al kernel (constante durante todo el bucle interior)
    mov     eax, [ebp + 24]

    ; ECX = i = 1  (indice ascendente del bucle interior)
    mov     ecx, 1

; ---- Bucle interior: for (i = 1; i < width-1; i++) ----
; EBX, ESI, EDI apuntan a columna i-1 de sus respectivas filas.
; EAX = kernel base; ECX = i (indice actual); EDX = salida columna i.
; EAX no es modificado por las instrucciones MAC ni de avance.
.inner:
    cmp     ecx, [ebp - 12]     ; i < i_limit ?
    jge     .next_row

    fldz                        ; ST0 = 0.0  (acumulador)

    ; -- Fila 0 (row j-1): kernel[0][0..2] --
    fld     dword [ebx]         ; ST0 = in[j-1, i-1]
    fmul    dword [eax]         ; * kernel[0][0]
    faddp   st1, st0            ; acc += producto

    fld     dword [ebx + 4]     ; in[j-1, i]
    fmul    dword [eax + 4]     ; * kernel[0][1]
    faddp   st1, st0

    fld     dword [ebx + 8]     ; in[j-1, i+1]
    fmul    dword [eax + 8]     ; * kernel[0][2]
    faddp   st1, st0

    ; -- Fila 1 (row j): kernel[1][0..2] --
    fld     dword [esi]         ; in[j, i-1]
    fmul    dword [eax + 12]    ; * kernel[1][0]
    faddp   st1, st0

    fld     dword [esi + 4]     ; in[j, i]
    fmul    dword [eax + 16]    ; * kernel[1][1]
    faddp   st1, st0

    fld     dword [esi + 8]     ; in[j, i+1]
    fmul    dword [eax + 20]    ; * kernel[1][2]
    faddp   st1, st0

    ; -- Fila 2 (row j+1): kernel[2][0..2] --
    fld     dword [edi]         ; in[j+1, i-1]
    fmul    dword [eax + 24]    ; * kernel[2][0]
    faddp   st1, st0

    fld     dword [edi + 4]     ; in[j+1, i]
    fmul    dword [eax + 28]    ; * kernel[2][1]
    faddp   st1, st0

    fld     dword [edi + 8]     ; in[j+1, i+1]
    fmul    dword [eax + 32]    ; * kernel[2][2]
    faddp   st1, st0

    ; -- Almacenar resultado y avanzar punteros --
    fstp    dword [edx]         ; out[j, i] = acc  (y vacia ST0)

    add     ebx, 4              ; row0: siguiente columna
    add     esi, 4              ; row1: siguiente columna
    add     edi, 4              ; row2: siguiente columna
    add     edx, 4              ; out:  siguiente columna

    inc     ecx                 ; i++
    jmp     .inner

.next_row:
    ; j++
    inc     dword [ebp - 16]
    jmp     .outer

.done:
    ; ---- Epilogo cdecl ----
    pop     edi
    pop     esi
    pop     ebx
    add     esp, 16             ; liberar variables locales
    pop     ebp
    ret                         ; el llamador (cdecl) limpia los 5 parametros
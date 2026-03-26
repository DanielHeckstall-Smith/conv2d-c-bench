; =============================================================================
; conv2d_sse.asm  -  Implementacion SSE packed (win32, cdecl)
; =============================================================================
;
; RECURSO:
;   - https://www.felixcloutier.com/x86/
;   - https://software.intel.com/sites/landingpage/IntrinsicsGuide/
;
; Expone el simbolo que benchmark.c necesita:
;   _conv2d_impl  funcion  -- convolucion 2D completa
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
; - Registros XMM: caller-saved en Win32 ABI de 32 bits (no necesitan preservarse).
;
; MAPA DE PILA tras prologo:
; ------------------------------------------
;   [ebp +  0] = ebp guardado
;   [ebp +  4] = direccion de retorno
;   [ebp +  8] = in      (const float*)
;   [ebp + 12] = out     (float*)
;   [ebp + 16] = width   (int)
;   [ebp + 20] = height  (int)
;   [ebp + 24] = kernel  (puntero a float[3][3])
;
; VARIABLES LOCALES (sub esp, 16 reserva 4 enteros — identico a conv2d_x87.asm):
; ------------------------------------------
;   [ebp -  4] = row_stride  width * 4  (bytes por fila)
;   [ebp -  8] = j_limit     height - 1 (limite bucle j)
;   [ebp - 12] = i_limit     width  - 1 (limite bucle i escalar: i < i_limit)
;   [ebp - 16] = j           indice del bucle exterior
;
; NOTA: i_sse_limit (width-4) no necesita variable propia porque las dimensiones
; son constantes de compilacion (WIDTH=3072, KERNEL_SIZE=3). Se deriva inline
; en la condicion del bucle SSE: i_limit - 3 == width - 4. Si quisieramos hacer 
; una version adaptable a distintas dimensiones de matriz de entrada, seria primordial.
;
;
; ASIGNACION DE REGISTROS (bucles interior)
; -----------------------------------------
;   EBX  = puntero a fila j-1 (row0), columna i-1  [no-volatil]
;   ESI  = puntero a fila j   (row1), columna i-1  [no-volatil]
;   EDI  = puntero a fila j+1 (row2), columna i-1  [no-volatil]
;   EDX  = puntero de escritura en out, columna i  [volatil, ok]
;   ECX  = indice i del bucle interior             [volatil, ok]
;   EAX  = puntero base del kernel                 [volatil, ok]
;
;
; ESTRATEGIA SSE PACKED: 4 pixeles de salida a la vez
; ----------------------------------------------------
; Para los pixeles de salida i, i+1, i+2, i+3 en la fila j,
; el calculo para el coeficiente k[r][c] es:
;
;   salida[i  ] += in[j+r-1][i  -1+c] * k[r][c]
;   salida[i+1] += in[j+r-1][i+1-1+c] * k[r][c]
;   salida[i+2] += in[j+r-1][i+2-1+c] * k[r][c]
;   salida[i+3] += in[j+r-1][i+3-1+c] * k[r][c]
;
; Empaquetando los 4 valores de entrada en un xmm:
;   c=0: movups xmm, [row_ptr]      -> {in[i-1], in[i],   in[i+1], in[i+2]}
;   c=1: movups xmm, [row_ptr + 4]  -> {in[i],   in[i+1], in[i+2], in[i+3]}
;   c=2: movups xmm, [row_ptr + 8]  -> {in[i+1], in[i+2], in[i+3], in[i+4]}
;
; Cada coeficiente del kernel se difunde a los 4 canales con shufps:
;   movss  xmm0, [eax + offset]   ; carga escalar
;   shufps xmm0, xmm0, 0          ; difunde a todos los canales
;
; El acumulador xmm7 acumula los 9 productos vectoriales (9 addps).
; Al final, movups [edx], xmm7 escribe los 4 resultados de una vez.
;
; Tras cada bloque de 4 pixeles los punteros de fila avanzan 16 bytes (4 floats).
;
; BUCLE ESCALAR DE COLA
; ----------------------
; Los pixeles restantes (0 a 3) se procesan con operaciones SSE escalares
; (movss, mulss, addss) para mantener coherencia numerica con el bucle vectorial.
;
; CONDICION DE LOS BUCLES
; ------------------------
;   Bucle SSE:    i < i_sse_limit  donde  i_sse_limit = width - 4
;                 Garantiza que i+3 <= width-2, es decir, los 4 pixeles
;                 de salida son todos validos.
;   Bucle escalar: i < i_limit     donde  i_limit     = width - 1
;                 Procesa los pixeles restantes de la fila.
;
; ACCESO AL KERNEL
; ----------------
; El kernel float[3][3] es contiguo en memoria (row-major):
;   [eax +  0] = k[0][0]   [eax + 12] = k[1][0]   [eax + 24] = k[2][0]
;   [eax +  4] = k[0][1]   [eax + 16] = k[1][1]   [eax + 28] = k[2][1]
;   [eax +  8] = k[0][2]   [eax + 20] = k[1][2]   [eax + 32] = k[2][2]
; =============================================================================

bits 32

section .text
global _conv2d_impl

_conv2d_impl:
    ; ---- Prologo cdecl ----
    push    ebp
    mov     ebp, esp
    sub     esp, 16             ; reservar 4 variables locales (identico a x87)
    push    ebx                 ; no-volatil
    push    esi                 ; no-volatil
    push    edi                 ; no-volatil

    ; ---- Precomputar constantes ----

    ; row_stride = width * 4
    mov     eax, [ebp + 16]     ; eax = width
    shl     eax, 2              ; eax = width * 4
    mov     [ebp - 4], eax      ; local: row_stride

    ; j_limit = height - 1
    mov     eax, [ebp + 20]     ; eax = height
    dec     eax
    mov     [ebp - 8], eax      ; local: j_limit

    ; i_limit = width - 1   (bucle escalar: i < i_limit)
    mov     eax, [ebp + 16]     ; eax = width
    dec     eax
    mov     [ebp - 12], eax     ; local: i_limit

    ; j = 1
    mov     dword [ebp - 16], 1

; ---- Bucle exterior: for (j = 1; j < height-1; j++) ----
.outer:
    mov     eax, [ebp - 16]     ; eax = j
    cmp     eax, [ebp - 8]      ; j < j_limit ?
    jge     .done

    ; Calcular punteros de fila con IMUL
    mov     ecx, [ebp - 4]      ; ecx = row_stride

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

    ; EAX = puntero al kernel
    mov     eax, [ebp + 24]

    ; ECX = i = 1
    mov     ecx, 1

; ---- Bucle SSE packed: procesa 4 pixeles a la vez ----
; EBX/ESI/EDI apuntan a columna i-1; EAX = kernel; ECX = i; EDX = salida columna i.
.sse_inner:
    mov     eax, [ebp - 12]     ; i_limit = width-1
    sub     eax, 3              ; width-4 = i_sse_limit (derivado, no variable propia)
    cmp     ecx, eax            ; i < i_sse_limit ?
    jge     .scalar_inner

    xorps   xmm7, xmm7          ; acumulador = {0, 0, 0, 0}

    ; ---- Fila 0 (row j-1): k[0][0], k[0][1], k[0][2] ----

    movss   xmm0, [eax + 0]     ; k[0][0]
    shufps  xmm0, xmm0, 0       ; difundir a los 4 canales
    movups  xmm1, [ebx]         ; {in[i-1], in[i], in[i+1], in[i+2]}
    mulps   xmm1, xmm0
    addps   xmm7, xmm1

    movss   xmm0, [eax + 4]     ; k[0][1]
    shufps  xmm0, xmm0, 0
    movups  xmm1, [ebx + 4]     ; {in[i], in[i+1], in[i+2], in[i+3]}
    mulps   xmm1, xmm0
    addps   xmm7, xmm1

    movss   xmm0, [eax + 8]     ; k[0][2]
    shufps  xmm0, xmm0, 0
    movups  xmm1, [ebx + 8]     ; {in[i+1], in[i+2], in[i+3], in[i+4]}
    mulps   xmm1, xmm0
    addps   xmm7, xmm1

    ; ---- Fila 1 (row j): k[1][0], k[1][1], k[1][2] ----

    movss   xmm0, [eax + 12]    ; k[1][0]
    shufps  xmm0, xmm0, 0
    movups  xmm1, [esi]
    mulps   xmm1, xmm0
    addps   xmm7, xmm1

    movss   xmm0, [eax + 16]    ; k[1][1]
    shufps  xmm0, xmm0, 0
    movups  xmm1, [esi + 4]
    mulps   xmm1, xmm0
    addps   xmm7, xmm1

    movss   xmm0, [eax + 20]    ; k[1][2]
    shufps  xmm0, xmm0, 0
    movups  xmm1, [esi + 8]
    mulps   xmm1, xmm0
    addps   xmm7, xmm1

    ; ---- Fila 2 (row j+1): k[2][0], k[2][1], k[2][2] ----

    movss   xmm0, [eax + 24]    ; k[2][0]
    shufps  xmm0, xmm0, 0
    movups  xmm1, [edi]
    mulps   xmm1, xmm0
    addps   xmm7, xmm1

    movss   xmm0, [eax + 28]    ; k[2][1]
    shufps  xmm0, xmm0, 0
    movups  xmm1, [edi + 4]
    mulps   xmm1, xmm0
    addps   xmm7, xmm1

    movss   xmm0, [eax + 32]    ; k[2][2]
    shufps  xmm0, xmm0, 0
    movups  xmm1, [edi + 8]
    mulps   xmm1, xmm0
    addps   xmm7, xmm1

    ; ---- Escribir 4 resultados y avanzar ----
    movups  [edx], xmm7         ; out[j, i..i+3] = {acc0, acc1, acc2, acc3}

    add     ebx, 16             ; row0: avanzar 4 floats (siguiente columna i-1)
    add     esi, 16             ; row1: avanzar 4 floats
    add     edi, 16             ; row2: avanzar 4 floats
    add     edx, 16             ; out:  avanzar 4 floats

    add     ecx, 4              ; i += 4
    jmp     .sse_inner

; ---- Bucle escalar de cola: pixeles restantes de la fila ----
; Usa operaciones SSE escalares (movss/mulss/addss) para mantener
; coherencia numerica con el bucle vectorial y evitar cambios de modo FPU.
.scalar_inner:
    cmp     ecx, [ebp - 12]     ; i < i_limit ?
    jge     .next_row

    xorps   xmm7, xmm7          ; acumulador escalar = 0.0

    ; ---- Fila 0 (row j-1) ----
    movss   xmm0, [eax + 0]
    movss   xmm1, [ebx]
    mulss   xmm1, xmm0
    addss   xmm7, xmm1

    movss   xmm0, [eax + 4]
    movss   xmm1, [ebx + 4]
    mulss   xmm1, xmm0
    addss   xmm7, xmm1

    movss   xmm0, [eax + 8]
    movss   xmm1, [ebx + 8]
    mulss   xmm1, xmm0
    addss   xmm7, xmm1

    ; ---- Fila 1 (row j) ----
    movss   xmm0, [eax + 12]
    movss   xmm1, [esi]
    mulss   xmm1, xmm0
    addss   xmm7, xmm1

    movss   xmm0, [eax + 16]
    movss   xmm1, [esi + 4]
    mulss   xmm1, xmm0
    addss   xmm7, xmm1

    movss   xmm0, [eax + 20]
    movss   xmm1, [esi + 8]
    mulss   xmm1, xmm0
    addss   xmm7, xmm1

    ; ---- Fila 2 (row j+1) ----
    movss   xmm0, [eax + 24]
    movss   xmm1, [edi]
    mulss   xmm1, xmm0
    addss   xmm7, xmm1

    movss   xmm0, [eax + 28]
    movss   xmm1, [edi + 4]
    mulss   xmm1, xmm0
    addss   xmm7, xmm1

    movss   xmm0, [eax + 32]
    movss   xmm1, [edi + 8]
    mulss   xmm1, xmm0
    addss   xmm7, xmm1

    ; ---- Almacenar resultado y avanzar ----
    movss   [edx], xmm7

    add     ebx, 4
    add     esi, 4
    add     edi, 4
    add     edx, 4

    inc     ecx                 ; i++
    jmp     .scalar_inner

.next_row:
    inc     dword [ebp - 16]    ; j++
    jmp     .outer

.done:
    ; ---- Epilogo cdecl ----
    pop     edi
    pop     esi
    pop     ebx
    add     esp, 16             ; liberar variables locales (identico a x87)
    pop     ebp
    ret                         ; el llamador (cdecl) limpia los 5 parametros

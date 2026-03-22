# =============================================================================
# Makefile  -  Benchmark Convolucion 2D
# =============================================================================
#
# HERRAMIENTAS REQUERIDAS:
#   cl / link   Visual Studio  (x86 Native Tools Command Prompt for VS)
#   nmake                      (incluido con Visual Studio)
#   NASM                       (portable, incluido en tools\nasm.exe)
#
# ENTORNO: ejecutar SIEMPRE desde "x86 Native Tools Command Prompt for VS".
#   cl.exe, link.exe y nmake deben estar en PATH.
#   NASM no requiere instalacion: se usa el binario de tools\nasm.exe.
#   Para compilar con GCC/MinGW consultar el apendice de COMPILACION.md.
#
# USO:
#   nmake            -> compila las tres versiones en bin\
#   nmake conv2d_c   -> solo la version C pura
#   nmake conv2d_x87 -> solo la version x87 FPU
#   nmake conv2d_simd-> solo la version SSE packed
#   nmake clean      -> elimina bin\
#
# Si se prefiere usar una instalacion de NASM del sistema en lugar del
# binario portable, sobreescribir la variable desde la linea de comandos:
#   nmake NASM=nasm
#
# NOTA SOBRE OPTIMIZACION:
#   El objetivo es comparar versiones entre si, no maximizar velocidad
#   absoluta. Se deshabilitan TODAS las transformaciones del compilador:
#     /Od        Sin ninguna optimizacion.
#     /arch:IA32 Impide que cl emita instrucciones SSE/SSE2 automaticamente.
#                Sin este flag, cl puede vectorizar el bucle C incluso con
#                /Od, dando a conv2d_c.exe una ventaja injusta frente a las
#                versiones ASM.
#   NASM traduce instrucciones 1:1: el binario refleja exactamente el .asm.
# =============================================================================

# ==========================================================================
# CONVENCION DE NOMBRES DE BINARIOS -- OBLIGATORIO
# ==========================================================================
# Los ejecutables de salida deben seguir el patron:
#
#   conv2d_<version>.exe
#
# run.ps1 identifica cada version a partir de la clave en $VERSION_LABELS.
# Un nombre no registrado en ese diccionario sera ignorado en los resultados.
# Si se cambia el nombre de un binario aqui, actualizar tambien run.ps1.
# ==========================================================================

# --------------------------------------------------------------------------
# Herramientas (sobreescribibles desde la linea de comandos)
# --------------------------------------------------------------------------
CC   = cl
LD   = link
NASM = tools\nasm.exe

MKBIN = if not exist $(BINDIR) mkdir $(BINDIR)

# --------------------------------------------------------------------------
# Flags cl.exe  -- SIN optimizaciones, SIN vectorizacion automatica
#   /Od        Deshabilita todas las optimizaciones
#   /W3        Nivel de avisos estandar
#   /TC        Tratar los fuentes como C. Seguro: cl solo recibe .c
#   /arch:IA32 Genera codigo x86 puro; prohibe SSE/SSE2 automatico
#   /nologo    Suprime el banner de version del compilador
# --------------------------------------------------------------------------
CFLAGS = /Od /W3 /TC /arch:IA32 /nologo

# --------------------------------------------------------------------------
# Flags link.exe
#   /nologo    Suprime el banner de version del enlazador
# --------------------------------------------------------------------------
LDFLAGS = /nologo

# --------------------------------------------------------------------------
# Flags NASM
#   -f win32   Objeto COFF/PE 32 bits, enlazable con link.exe
#   -w+all     Todos los avisos del ensamblador
# --------------------------------------------------------------------------
NASMFLAGS = -f win32 -w+all

# --------------------------------------------------------------------------
# Rutas
# --------------------------------------------------------------------------
BINDIR = bin

# ==========================================================================
# Target por defecto
# ==========================================================================
all: conv2d_c conv2d_x87 conv2d_simd

# ==========================================================================
# Objeto comun: benchmark.c compilado sin enlazar (/c).
# Compartido por las versiones x87 y simd para no compilarlo dos veces.
# cl solo recibe .c -> /TC es seguro.
# ==========================================================================
$(BINDIR)\benchmark.obj: benchmark.c benchmark.h
	$(MKBIN)
	$(CC) $(CFLAGS) /Fo:$(BINDIR)\ /c benchmark.c

# ==========================================================================
# Version C pura
# cl compila y enlaza en un solo paso. Solo .c -> /TC es seguro.
# ==========================================================================
conv2d_c: $(BINDIR)\conv2d_c.exe

$(BINDIR)\conv2d_c.exe: benchmark.c conv2d_c.c benchmark.h
	$(MKBIN)
	$(CC) $(CFLAGS) /Fo:$(BINDIR)\ /Fe:$@ benchmark.c conv2d_c.c

# ==========================================================================
# Version x87 FPU  (NASM + cl /c + link)
# Paso 1: NASM ensambla conv2d_x87.asm -> objeto COFF/PE 32 bits
# Paso 2: cl compila benchmark.c -> benchmark.obj  (target comun)
# Paso 3: link enlaza los dos objetos -> exe
# ==========================================================================
conv2d_x87: $(BINDIR)\conv2d_x87.exe

$(BINDIR)\conv2d_x87.obj: conv2d_x87.asm
	$(MKBIN)
	$(NASM) $(NASMFLAGS) conv2d_x87.asm -o $(BINDIR)\conv2d_x87.obj

$(BINDIR)\conv2d_x87.exe: $(BINDIR)\benchmark.obj $(BINDIR)\conv2d_x87.obj
	$(LD) $(LDFLAGS) /OUT:$@ $(BINDIR)\benchmark.obj $(BINDIR)\conv2d_x87.obj

# ==========================================================================
# Version SSE packed  (NASM + cl /c + link)
# Paso 1: NASM ensambla conv2d_sse.asm -> objeto COFF/PE 32 bits
# Paso 2: cl compila benchmark.c -> benchmark.obj  (target comun)
# Paso 3: link enlaza los dos objetos -> exe
# ==========================================================================
conv2d_simd: $(BINDIR)\conv2d_simd.exe

$(BINDIR)\conv2d_simd.obj: conv2d_sse.asm
	$(MKBIN)
	$(NASM) $(NASMFLAGS) conv2d_sse.asm -o $(BINDIR)\conv2d_simd.obj

$(BINDIR)\conv2d_simd.exe: $(BINDIR)\benchmark.obj $(BINDIR)\conv2d_simd.obj
	$(LD) $(LDFLAGS) /OUT:$@ $(BINDIR)\benchmark.obj $(BINDIR)\conv2d_simd.obj

# ==========================================================================
# Limpieza
# ==========================================================================
clean:
	if exist $(BINDIR) rmdir /s /q $(BINDIR)
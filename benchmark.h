/*
 * benchnmark.h
 * ==============
 * Definiciones, constantes y prototipos compartidos por todas
 * las versiones del benchmark de convolucion 2D.
 *
 * Cada implementacion (.c / .asm) debe exponer:
 *   - conv2d_impl(...)  con la firma definida abajo
 *   - IMPL_NAME         cadena literal con el nombre de la version
 */

#ifndef BENCH_COMMON_H
#define BENCH_COMMON_H

#define RESULTS_DIR  "results"

/* En pixeles                                                        */
/* Cada pixel ocupa un float, sizeof(float) = 4 bytes               */
#define WIDTH        3072
#define HEIGHT       3072

#define REPETITIONS  200
#define KERNEL_SIZE  3


extern const float KERNEL[KERNEL_SIZE][KERNEL_SIZE];

/*
 * Estadisticas de tiempo agrupadas en un unico struct.
 * Todos los campos en segundos; convertir a ms en la salida (*10^3).
 */
typedef struct {
    double min;
    double max;
    double mean;
    double stddev;
} BenchStats;

/* Calcula BenchStats sobre un array de n tiempos en segundos */
BenchStats compute_stats(const double* times, int n);

/* Generador de la imagen de prueba, en benchmark.c */
void generate_input(float* img, int width, int height);

/*
 * Funcion de convolucion — implementada en cada conv2d_*.c
 * Firma unica para que bench_main.c pueda llamarla sin conocer
 * los detalles internos de cada version.
 */
void conv2d_impl(const float* in, float* out, int width, int height,
    const float kernel[KERNEL_SIZE][KERNEL_SIZE]);

#endif /* BENCH_COMMON_H */
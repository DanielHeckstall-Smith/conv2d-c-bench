/*
 * conv2d_c.c
 * ==========
 * Implementacion en C puro de la convolucion 2D.
 *
 * Expone:
 *   - conv2d_impl() : Funcion que calcula la convolucion
 * 
 * Compilación:
 *   - Compilar sin optimizaciones (-O0)
 */

#include "benchmark.h"

/* ------------------------------------------------------------------ */    
/* No se calculan bordes
*  Los limites son 1..HEIGTH-2 y 1..WIDTH-2 (0-index)
* 
*  Para el pixel (j, i), los 9 vecinos son:                         
*   fila j-1: (j-1,i-1), (j-1,i), (j-1,i+1)                       
*   fila j  : (j,  i-1), (j,  i), (j,  i+1)                       
*   fila j+1: (j+1,i-1), (j+1,i), (j+1,i+1)                       
*/                                                                 
/* ------------------------------------------------------------------ */
static void conv2d_c(const float* in, float* out, int width, int height,
    const float kernel[KERNEL_SIZE][KERNEL_SIZE])
{
    for (int j = 1; j < height - 1; j++) {

        /* TRUCO PARA ENSAMBLADOR: Precalcular los offsets de las filas.
         * Así evitamos multiplicar j * width dentro del bucle interno.
         Reducir drásticamente el número de instrucciones de control estáticas */
        int row_prev = (j - 1) * width;
        int row_curr = j * width;
        int row_next = (j + 1) * width;

        for (int i = 1; i < width - 1; i++) {
            float acc = 0.0f;

            /* Fila superior */
            acc += in[row_prev + i - 1] * kernel[0][0];
            acc += in[row_prev + i]     * kernel[0][1];
            acc += in[row_prev + i + 1] * kernel[0][2];

            /* Fila central */
            acc += in[row_curr + i - 1] * kernel[1][0];
            acc += in[row_curr + i]     * kernel[1][1];
            acc += in[row_curr + i + 1] * kernel[1][2];

            /* Fila inferior */
            acc += in[row_next + i - 1] * kernel[2][0];
            acc += in[row_next + i]     * kernel[2][1];
            acc += in[row_next + i + 1] * kernel[2][2];

            out[row_curr + i] = acc;
        }
    }
}

/* Se debe exponer esta funcion con este mismo nombre */
void conv2d_impl(const float* in, float* out, int width, int height,
    const float kernel[KERNEL_SIZE][KERNEL_SIZE])
{
    conv2d_c(in, out, width, height, kernel);
}
/*
 * benchmark.c
 * ===========
 * Punto de entrada unico para el benchmark de convolucion 2D.
 *
 * Al terminar escribe automaticamente:
 *   <RESULTS_DIR>/result_<YYYYMMDD_HHMMSS>_<version>.txt
 *
 * Formato del fichero: una metrica por linea, KEY:VALUE.
 * run.ps1 lee ese fichero directamente sin parsear stdout.
 * 
 * Es responsabilidad del programador linkear este punto de entrada comun
 * con la implementación correspondiente y por tanto nombrar correctamente
 * el ejecutable de salida, ya que este programa usa argv[0] para nombrar el 
 * archivo de resultados. Este archivo es agnostico a la versión.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>

#include "benchmark.h"

 /* ------------------------------------------------------------------ */
 /* Kernel para aplicar fitro gaussiano normalizado.
 * Showcase de kernels mas usados: 
 *  - https://setosa.io/ev/image-kernels/
 * Este kernel en concreto puede generarse con una funcion matemática:
 *  - https://es.wikipedia.org/wiki/Desenfoque_gaussiano
 */
 /* ------------------------------------------------------------------ */
const float KERNEL[KERNEL_SIZE][KERNEL_SIZE] = {
    { 1.0f / 16, 2.0f / 16, 1.0f / 16 },
    { 2.0f / 16, 4.0f / 16, 2.0f / 16 },
    { 1.0f / 16, 2.0f / 16, 1.0f / 16 }
};

/* ------------------------------------------------------------------ */
/* Genera la imagen de entrada con valores pseudoaleatorios            */
/* Semilla fija para reproducibilidad entre versiones                 */
/* ------------------------------------------------------------------ */
void generate_input(float* img, int width, int height)
{
    srand(42);
    for (int i = 0; i < width * height; i++)
        img[i] = (float)(rand() % 255);
}

/* ------------------------------------------------------------------ */
/* Definimos una macro en funcion de donde se compile.
* Si estamos en WINDOWS, usaremos QueryPerformanceFrequency() para medir
* el tiempo de ejecuccion, que es lo recomendado por microsoft para precision
* 
* Si estamos en LINUX, usamos clock_gettime() con CLOCK_MONOTONIC, que indica
* que el reloj no puede modificarse y solo avanza. Linux recomienda este sistema
* para benchmarking
* 
* En ambos casos se define la implementacion para crear un directorio.
*/
/* ------------------------------------------------------------------ */
#ifdef _WIN32
#   include <windows.h>
#   include <direct.h>
static double get_time_seconds(void)
{
    LARGE_INTEGER freq, t;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&t);
    return (double)t.QuadPart / (double)freq.QuadPart;
}
static void make_results_dir(void) { _mkdir(RESULTS_DIR); }
#else
#   include <sys/stat.h>
static double get_time_seconds(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}
static void make_results_dir(void) { mkdir(RESULTS_DIR, 0755); }
#endif

/* ------------------------------------------------------------------ */
/* Estadisticas                                                        */
/* ------------------------------------------------------------------ */
BenchStats compute_stats(const double* times, int n)
{
    double sum = 0.0;
    double mn = times[0];
    double mx = times[0];

    for (int i = 0; i < n; i++) {
        sum += times[i];
        if (times[i] < mn) mn = times[i];
        if (times[i] > mx) mx = times[i];
    }
    double mean = sum / n;

    double variance = 0.0;
    for (int i = 0; i < n; i++) {
        double d = times[i] - mean;
        variance += d * d;
    }

    BenchStats s;
    s.min = mn;
    s.max = mx;
    s.mean = mean;
    s.stddev = sqrt(variance / n);
    return s;
}

/* ------------------------------------------------------------------ */
int main(int argc, char* argv[])
{
    (void)argc;


    /* ------------------------------------------------------------------ */
    /*
     * Extraer el nombre del ejecutable de argv[0] para usarlo en el
     * nombre del fichero de resultados.
     * Ejemplo: "bin/conv2d_SSE.exe" -> "conv2d_SSE"
     */
    const char* exe_path = argv[0];
    int start_idx = 0;
   
    for (int i = 0; exe_path[i] != '\0'; i++) {
        if (exe_path[i] == '/' || exe_path[i] == '\\') {
            start_idx = i + 1; 
        }
    }

    char exe_name[64];
    int n = 0;

    for (int i = start_idx; exe_path[i] != '\0' && exe_path[i] != '.'; i++) {
        if (n < 63) {
            exe_name[n] = exe_path[i];
            n++;
        }
    }
    exe_name[n] = '\0';
    /* ------------------------------------------------------------------ */


    float* input = (float*)malloc(WIDTH * HEIGHT * sizeof(float));
    float* output = (float*)malloc(WIDTH * HEIGHT * sizeof(float));
    double* times = (double*)malloc(REPETITIONS * sizeof(double));
    if (!input || !output || !times) { perror("malloc"); return 1; }

    generate_input(input, WIDTH, HEIGHT);

    /* Calentamiento: 10 veces */
    for (int i = 0; i < 11; i++) {
        conv2d_impl(input, output, WIDTH, HEIGHT, KERNEL);
    }

    /* Medicion */
    for (int r = 0; r < REPETITIONS; r++) {
        double t0 = get_time_seconds();
        conv2d_impl(input, output, WIDTH, HEIGHT, KERNEL);
        times[r] = get_time_seconds() - t0;
    }

    /* -- Metricas ---------------------------------- */
    BenchStats s = compute_stats(times, REPETITIONS);

    // Se toma la media de tiempo/repeticion para el tiempo total
    double total_elapsed = s.mean * REPETITIONS;
    // Por repeticion:
    // Un pixel representa un float de tamano sizeof(float) bytes (normalmente esto es 4)
    // La matriz de entrada tiene (WIDTH - 1) * (HEIGHT - 1) pixels
    // Por 2.0
    double bytes_per_rep = 2.0 * (WIDTH - 1) * (HEIGHT - 1) * sizeof(float);
    double total_mb = (bytes_per_rep * REPETITIONS) / (1024.0 * 1024.0);
    double throughput_mbs = total_mb / total_elapsed;

    // Estas formulas están explicadas en el word
    int       valid_rows = HEIGHT - 2;
    int       valid_cols = WIDTH - 2;
    long long total_pixels = (long long)valid_rows * valid_cols;
    int       packed_per_row = valid_cols / 4;
    int       scalar_per_row = valid_cols % 4;

    // 18LL -> Para un kernel 3x3 -> 9 ops/pixel x 2 (entrada-salida)
    long long flops_per_rep = 18LL * total_pixels;
    double    gflops = (s.mean > 0.0)
        ? (double)flops_per_rep / (s.mean * 1e9)
        : 0.0;

    /* El checksum debe ser igual en todas las versiones 
    *  para asegurar la integridad correcta de los resultados.
    */
    double checksum = 0.0;
    for (int j = 1; j < HEIGHT - 1; j++)
        for (int i = 1; i < WIDTH - 1; i++)
            checksum += output[j * WIDTH + i];

    /* -- Escribir fichero KEY:VALUE ---------------------------------- */
    make_results_dir();

    time_t     now = time(NULL);
    struct tm* tm = localtime(&now);
    char       ts[16];
    strftime(ts, sizeof(ts), "%Y%m%d_%H%M%S", tm);

    char filepath[256];
    snprintf(filepath, sizeof(filepath),
        RESULTS_DIR "/result_%s_%s.txt", ts, exe_name);

    FILE* f = fopen(filepath, "w");
    if (!f) {
        perror("fopen result");
    }
    else {
        fprintf(f, "VERSION:%s\n", exe_name);
        fprintf(f, "IMG_WIDTH:%d\n", WIDTH);
        fprintf(f, "IMG_HEIGHT:%d\n", HEIGHT);
        fprintf(f, "KERNEL_SIZE:%d\n", KERNEL_SIZE);
        fprintf(f, "REPETITIONS:%d\n", REPETITIONS);
        fprintf(f, "TIME_TOTAL_S:%.4f\n", total_elapsed);
        fprintf(f, "TIME_MEAN_MS:%.3f\n", s.mean * 1e3);
        fprintf(f, "TIME_MIN_MS:%.3f\n", s.min * 1e3);
        fprintf(f, "TIME_MAX_MS:%.3f\n", s.max * 1e3);
        fprintf(f, "TIME_STDDEV_MS:%.3f\n", s.stddev * 1e3);
        fprintf(f, "TIME_STDDEV_PCT:%.1f\n",
            s.mean > 0.0 ? (s.stddev / s.mean) * 100.0 : 0.0);
        fprintf(f, "THROUGHPUT_MBS:%.2f\n", throughput_mbs);
        fprintf(f, "GFLOPS:%.4f\n", gflops);
        fprintf(f, "VALID_ROWS:%d\n", valid_rows);
        fprintf(f, "VALID_COLS:%d\n", valid_cols);
        fprintf(f, "TOTAL_PIXELS:%lld\n", total_pixels);
        fprintf(f, "PACKED_PER_ROW:%d\n", packed_per_row);
        fprintf(f, "SCALAR_PER_ROW:%d\n", scalar_per_row);
        fprintf(f, "CHECKSUM:%.4f\n", checksum);
        fclose(f);
        printf("  Results saved to: %s\n\n", filepath);
    }

    free(input);
    free(output);
    free(times);
    return 0;
}
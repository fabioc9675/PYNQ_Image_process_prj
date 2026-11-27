# PYNQ_Image_process_prj

Project to make an example of image processing acceleration in hardware

Ejemplo para **PYNQ-Z1** (Zynq `xc7z020clg400-1`) que compara filtros de imagen
hechos en software (Python en el PS) contra los mismos filtros hechos en
hardware (PL), enviando la imagen por AXI DMA.

Incluye dos filtros AXI4-Stream en VHDL:

| Filtro | Operacion | Overlay | Notebook |
|---|---|---|---|
| `red_filter_axis` | Invierte el canal rojo de una imagen RGB (`R' = 255 - R`) | `image_p` | `Red_Filter.ipynb` |
| `sobel_axis` | Deteccion de bordes Sobel 3x3 en escala de grises | `sobel_p` | `Sobel_filter.ipynb` |

Un resumen detallado de todo el desarrollo, decisiones y resultados esta en
[RESUMEN.md](RESUMEN.md).

## Arquitectura

```
            HP0 (64 bits)                    GP0
 DDR <-------------------- AXI DMA <------------------ PS7 (registros 0x4040_0000)
                           |      ^
               M_AXIS_MM2S |      | S_AXIS_S2MM
                           v      |
                 filtro AXI4-Stream (VHDL)
          red_filter_axis  o  sobel_axis

 FCLK_CLK0 = 100 MHz para toda la logica del PL
```

- **AXI DMA** en modo simple (sin Scatter-Gather), streams de 64 bits.
- Ambos filtros tienen la misma interfaz (`s_axis` / `m_axis` de 64 bits), asi
  que se intercambian en el block design sin tocar nada mas.
- Ambos procesan **1 palabra de 64 bits por ciclo** y todo su pipeline avanza
  solo con el handshake AXI4-Stream, por lo que soportan backpressure.

### `red_filter_axis`

Recibe los bytes RGB empaquetados (R,G,B,R,G,B,...) en palabras de 8 bytes.
Como un pixel ocupa 3 bytes, los pixeles no quedan alineados con las palabras:
el modulo lleva la fase `byte mod 3`, que avanza 0 -> 2 -> 1 -> 0 en cada
palabra y se reinicia con `TLAST`.

### `sobel_axis`

- **Formato:** escala de grises de 8 bits, 8 pixeles por palabra. El ancho W
  debe ser multiplo de 8 y como maximo 4096 (`MAX_WORDS = 512`).
- **Paquete DMA:** `[cabecera: W/8] [imagen H x W/8 palabras] [3 palabras de relleno]`.
  La cabecera se reenvia tal cual a la salida.
- **Line buffers:** dos filas en RAM distribuida (lectura asincrona).
- **Calculo:** 8 pixeles Sobel por ciclo, `|Gx| + |Gy|` saturado a 255, en dos
  etapas de pipeline (gradientes, luego magnitud) para cerrar timing a 100 MHz.
- **Latencia:** la salida sale atrasada `W/8 + 3` palabras (`W + 24` pixeles);
  Python la reacomoda. Los bordes de la imagen no se calculan (se ponen en 0).

## Archivos

| Archivo | Descripcion |
|---|---|
| `Vivado/src/red_filter_axis.vhd` | Filtro AXI4-Stream que invierte R |
| `Vivado/src/sobel_axis.vhd` | Filtro AXI4-Stream Sobel 3x3 en gris |
| `Vivado/sim/tb_red_filter_axis.vhd` | Testbench autoverificable del filtro rojo |
| `Vivado/sim/tb_sobel_axis.vhd` | Testbench autoverificable del Sobel (modelo de referencia en VHDL) |
| `Vivado/bd/pynq_bd/pynq_bd.bd` | Block design: PS7 + AXI DMA + filtro (actualmente `sobel_axis`) |
| `Vivado/bd/pynq_bd/hdl/pynq_bd_wrapper.vhd` | Wrapper del BD (top del proyecto) |
| `Vivado/Top/pynq_image_prj/` | Proyecto Hog (`hog.conf` y listas de archivos) |
| `Vitis/image_p.bit`, `Vitis/image_p.hwh` | Overlay con el filtro rojo |
| `Vitis/sobel_p.bit`, `Vitis/sobel_p.hwh` | Overlay con el filtro Sobel |
| `Vitis/Red_Filter.ipynb` | Benchmark PS vs PL del filtro rojo |
| `Vitis/Sobel_filter.ipynb` | Benchmark del Sobel: NumPy, OpenCV y PL, mas analisis de precision |
| `Vitis/images/colors.jpg` | Imagen de prueba |

## Entorno

### Recomiendo trabajar con Git Bash

Para correr Vivado desde consola primero se debe agregar al `PATH`:

```bash
export PATH="/d/Xilinx/Vivado/2022.2/bin:$PATH"
```

Para clonar el repositorio con exito y sin errores usar la siguiente linea:

```bash
git clone -b devFabian --recurse-submodules https://github.com/fabioc9675/PYNQ_Image_process_prj.git
```

Con `--recurse-submodules` se clona completo el submodulo de Hog, y con
`-b devFabian` se clona el branch de trabajo.

## Hog

Todos los comandos se corren desde `Vivado/`.

Para convertir un proyecto existente en Hog (solo la primera vez):

```bash
./Hog/Init.sh
```

Con esto Hog escanea los proyectos en `Projects/` y crea el directorio `Top`
con la configuracion de cada uno.

Crear el proyecto (queda en `Vivado/Projects/pynq_image_prj`):

```bash
./Hog/Do CREATE pynq_image_prj
```

Generar el bitstream:

```bash
./Hog/Do WORKFLOW pynq_image_prj
```

El `.hwh` se genera en `Vivado/bd/pynq_bd/hw_handoff/pynq_bd.hwh`.

El block design actual usa `sobel_axis`. Para volver a generar el overlay del
filtro rojo, reemplazar el modulo en el BD por `red_filter_axis` (mismas conexiones).

## Simulacion

En Vivado: *Add Sources* -> *Add or create simulation sources* -> el testbench,
ponerlo como top de simulacion, *Run Behavioral Simulation* y `run all`.

| Testbench | Salida esperada |
|---|---|
| `tb_red_filter_axis.vhd` | `Note: TEST OK: 21 palabras correctas` |
| `tb_sobel_axis.vhd` | `Note: TEST OK: 240 pixels` |

Ambos prueban huecos aleatorios en `TVALID`, backpressure aleatorio en `TREADY`
y varios paquetes seguidos.

## Prueba en la PYNQ

1. Copiar a una misma carpeta de la PYNQ el `.bit` y el `.hwh` (deben tener el
   mismo nombre), el notebook y `colors.jpg`.
2. Abrir el notebook en Jupyter y correr todas las celdas.

Los benchmarks miden **solo el procesamiento**: la imagen ya esta en el buffer de
la DMA antes de iniciar el cronometro, y el PS trabaja sobre memoria normal
escribiendo en un buffer ya reservado. Los tiempos son la mediana de 10 corridas.

### Resultados: filtro rojo (RGB)

| Tamano | PS (NumPy) | PL (flush + DMA + inval) | Speedup |
|---|---|---|---|
| 640x480 (0.9 MB) | 8.01 ms | 2.48 ms | 3.2x |
| 1920x1080 (6.2 MB) | 50.94 ms | 9.14 ms | 5.6x |
| 3840x2160 (24.9 MB) | 213.55 ms | 32.50 ms | 6.6x |
| 4000x3000 (36.0 MB) | 316.23 ms | 46.46 ms | 6.8x |

El PL esta limitado por el ancho de banda: la DMA llega a 784 MB/s, cerca del
maximo teorico de 800 MB/s (64 bits a 100 MHz).

### Resultados: Sobel (gris)

| Tamano | NumPy | OpenCV 4.5.4 | PL | Speedup vs OpenCV |
|---|---|---|---|---|
| 640x480 (0.3 MP) | 118.71 ms | 66.86 ms | 1.67 ms | 40x |
| 1920x1080 (2.1 MP) | 798.74 ms | 461.41 ms | 3.92 ms | 118x |
| 3840x2160 (8.3 MP) | 3185.71 ms | 1855.63 ms | 11.78 ms | 157x |
| 4000x3000 (12.0 MP) | 4605.79 ms | 2718.79 ms | 16.45 ms | 165x |

- La salida del PL es **identica bit a bit** a NumPy y a OpenCV.
- **Nota:** el OpenCV instalado en la imagen de PYNQ (Ubuntu armhf) esta
  compilado **sin NEON**. Con un OpenCV optimizado con NEON se estima que el
  speedup bajaria a un rango de 20-40x (estimacion, no medida).

### Precision del Sobel (`colors.jpg`)

| Comparacion | max error | MAE | PSNR |
|---|---|---|---|
| PL vs PS (NumPy) | 0 | 0 | inf (identicos) |
| PL vs ideal `sqrt(Gx^2 + Gy^2)` en float | 74.4 | 9.64 | 24.11 dB |

El error contra el ideal viene de la aproximacion `|Gx| + |Gy|` (sobrestima hasta
~41 % en bordes diagonales), no del hardware.

---

Create by: Fabian Castaño

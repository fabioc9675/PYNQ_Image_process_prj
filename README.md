# PYNQ_Image_process_prj

Project to make an example of image processing acceleration in hardware

Ejemplo para **PYNQ-Z1** (Zynq `xc7z020clg400-1`) que compara un filtro de imagen
hecho en software (Python/NumPy en el PS) contra el mismo filtro hecho en
hardware (PL), enviando la imagen por AXI DMA.

El filtro **invierte el canal rojo** de cada pixel (`R' = 255 - R`); G y B no cambian.

## Arquitectura

```
            HP0 (64 bits)                    GP0
 DDR <-------------------- AXI DMA <------------------ PS7 (registros 0x4040_0000)
                           |      ^
               M_AXIS_MM2S |      | S_AXIS_S2MM
                           v      |
                       red_filter_axis (VHDL)

 FCLK_CLK0 = 100 MHz para toda la logica del PL
```

- **AXI DMA** en modo simple (sin Scatter-Gather), streams de 64 bits.
- **`red_filter_axis`** recibe los bytes RGB empaquetados (R,G,B,R,G,B,...) en
  palabras de 64 bits (8 bytes). Como un pixel ocupa 3 bytes, los pixeles no
  quedan alineados con las palabras: el modulo lleva la fase `byte mod 3`, que
  avanza 0 -> 2 -> 1 -> 0 en cada palabra y se reinicia con `TLAST`.
  Tiene un registro de salida, asi que procesa 1 palabra por ciclo.

## Archivos

| Archivo | Descripcion |
|---|---|
| `Vivado/src/red_filter_axis.vhd` | Filtro AXI4-Stream (invierte R) |
| `Vivado/sim/tb_red_filter_axis.vhd` | Testbench autoverificable con backpressure (imprime `TEST OK`) |
| `Vivado/bd/pynq_bd/pynq_bd.bd` | Block design: PS7 + AXI DMA + filtro |
| `Vivado/bd/pynq_bd/hdl/pynq_bd_wrapper.vhd` | Wrapper del BD (top del proyecto) |
| `Vivado/Top/pynq_image_prj/` | Proyecto Hog (`hog.conf` y listas de archivos) |
| `Vitis/image_p.bit`, `Vitis/image_p.hwh` | Overlay listo para cargar en la PYNQ |
| `Vitis/Red_Filter.ipynb` | Notebook de benchmark PS vs PL |
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

## Simulacion

En Vivado: *Add Sources* -> *Add or create simulation sources* ->
`Vivado/sim/tb_red_filter_axis.vhd`, ponerlo como top de simulacion,
*Run Behavioral Simulation* y `run all`. Debe imprimir:

```
Note: TEST OK: 21 palabras correctas
```

## Prueba en la PYNQ

1. Copiar a una misma carpeta de la PYNQ `image_p.bit`, `image_p.hwh`
   (deben tener el mismo nombre), `Red_Filter.ipynb` y `colors.jpg`.
2. Abrir el notebook en Jupyter y correr todas las celdas.

El notebook aplica el filtro en el PS y en el PL, verifica que ambos resultados
sean identicos y compara los tiempos (mediana de 20 corridas, de extremo a extremo).

### Resultados (imagen de 1.44 MB)

| Camino | Tiempo |
|---|---|
| PS (NumPy) | 20.21 ms |
| PL total (copias + DMA) | 16.49 ms (speedup 1.23x) |
| Solo DMA | 2.68 ms (536.8 MB/s) |

El PL calcula unas 7 veces mas rapido que NumPy, pero cerca del 84 % de su tiempo
total se va en copiar la imagen hacia y desde los buffers de la DMA.

---

Create by: Fabian Castaño

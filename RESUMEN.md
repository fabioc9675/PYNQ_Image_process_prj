# Resumen del proyecto

Este documento resume el desarrollo completo del proyecto: los objetivos, cada
etapa, las decisiones de diseno, los problemas encontrados y los resultados.
Para instrucciones de uso ver el [README](README.md).

## Objetivo

Construir un ejemplo con la **PYNQ-Z1** que mida si vale la pena acelerar en
hardware el procesamiento de una imagen:

1. **Camino PS:** procesar la imagen en software, en Python, sobre el ARM Cortex-A9.
2. **Camino PL:** enviar la imagen por AXI DMA al PL, procesarla en un filtro
   escrito en VHDL, devolverla al PS y reconstruirla en Python.
3. **Comparar** los tiempos de ambos caminos y verificar que den el mismo resultado.

**Herramientas:** Vivado 2022.2, Hog para el manejo del proyecto en git, PYNQ
con Jupyter, VHDL para todo el hardware.

---

## Etapa 1: proyecto base y loopback por DMA

### Proyecto en Hog

- El proyecto de Vivado vive en `Vivado/Projects/pynq_image_prj`. Hog exige esa
  ruta: con el proyecto fuera de `Projects/`, sus scripts fallaban con
  `couldn't read /Hog/Tcl/utils/check_list_files.tcl`.
- Flujo: `./Hog/Init.sh` (una vez), `./Hog/Do CREATE pynq_image_prj` y
  `./Hog/Do WORKFLOW pynq_image_prj`.
- Las listas de archivos estan en `Vivado/Top/pynq_image_prj/list/`:
  `ips.src` (el block design) y `xil_defaultlib.src` (VHDL y wrapper, con
  `top=pynq_bd_wrapper`).

### Block design

```
PS7 --GP0--> AXI Interconnect --> AXI DMA (S_AXI_LITE, 0x4040_0000)
AXI DMA --M_AXI_MM2S / M_AXI_S2MM--> SmartConnect --> S_AXI_HP0 (64 bits) --> DDR
AXI DMA M_AXIS_MM2S --> [filtro] --> AXI DMA S_AXIS_S2MM
FCLK_CLK0 = 100 MHz, reset = rst_ps7_0_100M/peripheral_aresetn
```

- AXI DMA en modo simple (sin Scatter-Gather), streams de 64 bits, registro de
  longitud de 26 bits (hasta 64 MB por transferencia).
- Primero se uso una `axis_data_fifo` como "filtro" para probar un loopback.

### Problemas resueltos

- **`.gitignore`:** la regla `BD/*` tambien ignoraba la carpeta `bd/` porque git
  en Windows no distingue mayusculas (`core.ignorecase=true`). Se reemplazo por
  reglas que solo conservan `pynq_bd.bd` y `pynq_bd_wrapper.vhd`.
- **`M_AXI_GP0_ACLK` sin conectar** (error `BD 41-758` en `CREATE`): se resolvio
  conectando `FCLK_CLK0` a ese puerto.
- **Overlay en PYNQ:** `Overlay("image_p.bit")` solo necesita el `.hwh` con el
  mismo nombre; el `.tcl` no hace falta.

### Resultado del loopback

La imagen volvio identica. Primera transferencia de 1.44 MB: 8.94 ms (161 MB/s).
Ese numero resulto ser una corrida "en frio"; la mediana de varias corridas fue
mucho menor (ver etapa 3).

---

## Etapa 2: filtro `red_filter_axis`

### Funcion

Primero se elimino el canal rojo (R = 0) y despues se cambio a **invertirlo**
(`R' = 255 - R`), que da tonos cyan en vez de una imagen sin rojo.

### Diseno

- Entrada: bytes RGB888 empaquetados, 8 bytes por palabra de 64 bits,
  little-endian (el byte 0 es `tdata(7 downto 0)`).
- Como 8 no es multiplo de 3, los pixeles cruzan las palabras. El modulo lleva
  la **fase** = indice del primer byte de la palabra `mod 3`. Avanza
  `0 -> 2 -> 1 -> 0` (8 mod 3 = 2) y se reinicia con `TLAST`.
- El byte `i` de una palabra es R si `(fase + i) mod 3 = 0`.
- Hardware: cada bit de salida es un LUT de 3 entradas (bit de dato + 2 bits de
  fase), unos 64 LUTs en total.
- Registro de salida estandar AXI4-Stream: `tready = not valid_r or m_axis_tready`.
  Procesa 1 palabra por ciclo y soporta backpressure.

### Verificacion

`tb_red_filter_axis.vhd` es un testbench autoverificable. Usa paquetes de 7 palabras (56 bytes, no multiplo de 3) para
que la fase termine en 2 y se compruebe el reinicio con `TLAST` en el segundo
paquete. Incluye huecos aleatorios en `TVALID` y backpressure aleatorio en
`TREADY`. Resultado: `TEST OK: 21 palabras correctas`.

---

## Etapa 3: un benchmark justo

El primer benchmark mezclaba procesamiento con copias de memoria. Se refino en
tres pasos, y cada uno cambio las conclusiones.

### 3.1 Extremo a extremo, con copias (imagen de 1.44 MB)

| Camino | Tiempo |
|---|---|
| PS (NumPy) | 20.21 ms |
| PL total (copia a buffer + DMA + copia de vuelta) | 16.49 ms (1.23x) |
| Solo DMA | 2.68 ms (536.8 MB/s) |

El 84 % del tiempo del PL eran las copias hacia y desde los buffers de la DMA.

### 3.2 Barrido de tamanos, con copias

| Tamano | PS | PL total | DMA | MB/s | Speedup |
|---|---|---|---|---|---|
| 640x480 (0.9 MB) | 13.01 ms | 11.37 ms | 2.06 ms | 446.7 | 1.14x |
| 1920x1080 (6.2 MB) | 94.59 ms | 66.67 ms | 8.71 ms | 714.0 | 1.42x |
| 3840x2160 (24.9 MB) | 368.00 ms | 258.93 ms | 32.00 ms | 777.5 | 1.42x |
| 4000x3000 (36.0 MB) | 546.13 ms | 378.03 ms | 45.94 ms | 783.6 | 1.44x |

- La DMA se satura en ~784 MB/s, el 98 % de lo que da un stream de 64 bits a 100 MHz.
- Un buffer de 72 MB fallo en `allocate`: el limite real es la memoria contigua
  (CMA) de la placa, no el registro de 64 MB de la DMA.

### 3.3 Sin copias (version final)

- La imagen se escribe en el buffer de la DMA **antes** de iniciar el cronometro,
  como haria un pipeline real (camara o decodificador escribiendo ahi).
- El PS trabaja sobre memoria normal y escribe en un buffer ya reservado.
- Se miden por separado `flush`, DMA e `invalidate`.

**Hallazgo:** `flush` e `invalidate` tardan ~0.3 y ~0.14 ms sin importar el
tamano: los buffers de `allocate` en esta PYNQ **no usan cache**, asi que esas
llamadas no hacen nada. Un primer intento midio el PS leyendo del buffer sin
cache, lo que lo hacia ~3 veces mas lento e inflaba el speedup a 20x. Se
corrigio para que el PS lea de memoria normal.

| Tamano | PS | flush | DMA | inval | PL | Speedup |
|---|---|---|---|---|---|---|
| 640x480 (0.9 MB) | 8.01 ms | 0.31 | 2.02 | 0.14 | 2.48 ms | 3.2x |
| 1920x1080 (6.2 MB) | 50.94 ms | 0.32 | 8.68 | 0.14 | 9.14 ms | 5.6x |
| 3840x2160 (24.9 MB) | 213.55 ms | 0.32 | 32.03 | 0.14 | 32.50 ms | 6.6x |
| 4000x3000 (36.0 MB) | 316.23 ms | 0.33 | 45.97 | 0.15 | 46.46 ms | 6.8x |

**Conclusion del filtro rojo:** el PL es hasta 6.8x mas rapido, limitado por el
ancho de banda. La operacion es tan simple que el PS tambien esta limitado por la
memoria (~114 MB/s).

### Analisis: subir el reloj a 200 MHz

Se estimo (sin implementarlo) que daria solo ~10-20 % de mejora:

- La DMA ya mueve ~1.57 GB/s en total (lee y escribe a la vez), cerca de lo que
  da en la practica la DDR3 de 16 bits de la PYNQ-Z1 (~1.6-1.8 GB/s).
- Los puertos HP del Zynq en speed grade -1 tienen un limite de frecuencia
  cercano a 150 MHz (verificar en DS187).

---

## Etapa 4: filtro `sobel_axis`

### Algoritmo

```
        Gx                     Gy
   -1   0  +1             -1  -2  -1
   -2   0  +2              0   0   0
   -1   0  +1             +1  +2  +1

   mag = min(|Gx| + |Gy|, 255)
```

`|Gx| + |Gy|` es la aproximacion estandar de `sqrt(Gx^2 + Gy^2)` en hardware:
no necesita multiplicadores. Los gradientes van de -1020 a 1020 (11 bits con signo).

### Decisiones de diseno

| Decision | Motivo |
|---|---|
| Escala de grises, 8 pixeles por palabra | Pixeles alineados con las palabras; con RGB empaquetado la ventana 3x3 seria muy compleja. Ademas se mueve 1/3 de los datos. |
| Ancho en una **cabecera** (primera palabra = W/8) | Evita agregar registros AXI-Lite. La cabecera se reenvia para que la salida mida lo mismo que la entrada. |
| Line buffers en **RAM distribuida** | Lectura asincrona: todo el pipeline avanza solo con el handshake, igual que el filtro rojo. ~1000 LUTs para W hasta 4096. |
| 8 pixeles Sobel por ciclo | El tiempo del PL queda igual al de la DMA. |
| Bordes sin calcular | Python los pone en 0 en ambos caminos y compara solo el interior. |
| Palabras de relleno al final | Por la latencia, los ultimos bloques solo salen si entran palabras despues de la imagen. |

### Ventana

Al llegar el bloque `x` de la fila `y` se leen de los line buffers los bloques
`x` de las filas `y-1` y `y-2`. Con registros de las palabras anteriores se arma
una ventana de 3 filas x 10 pixeles y se calculan los 8 pixeles de un bloque de
la fila `y-1`.

### Timing

| Version | WNS a 100 MHz |
|---|---|
| Ventana leida directo de la RAM + Sobel en un ciclo | **-0.483 ns** (ruta: `col` -> RAM distribuida con fanout 1036 -> 4 CARRY4 -> `data_r`, 10.3 ns) |
| Ventana solo desde registros | -0.046 ns (prueba fuera de contexto: quedaba solo la aritmetica) |
| + Sobel en 2 etapas (gradientes / magnitud) | **+1.075 ns** en el diseno completo |

Cada etapa nueva avanza una vez por palabra que entra, no por ciclo, asi que el
backpressure sigue funcionando. El costo es mas latencia: la salida queda
atrasada `W/8 + 3` palabras, y el paquete lleva 3 palabras de relleno.

Recursos del diseno completo (antes del pipeline): 4443 LUT, 4040 FF, 9 BRAM
(las BRAM son de la DMA). El filtro solo, con pipeline: ~1870 LUT y ~930 FF.

### Verificacion

`tb_sobel_axis.vhd` genera dos imagenes pseudoaleatorias de 32x6, calcula el
Sobel esperado con un modelo en VHDL y compara todos los pixeles interiores,
la cabecera y `TLAST`, con huecos en `TVALID` y backpressure. Tambien comprueba
que se revisaron todos los pixeles interiores, para que falte una palabra de
relleno no pase desapercibido. Resultado: `TEST OK: 240 pixels`.

### Resultados en la PYNQ

**Precision (`colors.jpg`):**

| Comparacion | max error | MAE | pixeles distintos | PSNR |
|---|---|---|---|---|
| PL vs PS (NumPy) | 0 | 0 | 0 % | inf |
| PL vs ideal `sqrt(Gx^2 + Gy^2)` | 74.4 | 9.64 | 89.2 % | 24.11 dB |

El PL es identico bit a bit al software. El error contra el ideal es propio de la
formula `|Gx| + |Gy|` (sobrestima hasta ~41 % en diagonales); 4.44 % de los
pixeles saturan en 255.

**Rendimiento:**

| Tamano | NumPy | OpenCV | PL | DMA | vs NumPy | vs OpenCV |
|---|---|---|---|---|---|---|
| 640x480 | 118.71 ms | 66.86 ms | 1.67 ms | 1.25 ms | 69x | 40x |
| 1920x1080 | 798.74 ms | 461.41 ms | 3.92 ms | 3.47 ms | 204x | 118x |
| 3840x2160 | 3185.71 ms | 1855.63 ms | 11.78 ms | 11.30 ms | 270x | 157x |
| 4000x3000 | 4605.79 ms | 2718.79 ms | 16.45 ms | 15.96 ms | 280x | 165x |

(La columna PL de NumPy y la de OpenCV vienen de corridas distintas; difieren en
menos de 0.1 ms.)

**OpenCV sin NEON:** `cv2.getBuildInformation()` muestra `Baseline` y
`CPU/HW features` vacios. El OpenCV de la imagen de PYNQ (Ubuntu armhf) esta
compilado sin SIMD: `convertScaleAbs` tarda 800 ms para 12 M de elementos y usar
1 o 2 hilos da el mismo tiempo. Con un OpenCV compilado con NEON el speedup se
estima en 20-40x (no medido).

---

## Conclusiones

1. **Con operaciones simples, el limite es mover datos.** En el filtro rojo, el
   PL calcula al ritmo de la DMA (~784 MB/s), pero el speedup se queda en ~7x
   porque el PS tambien esta limitado por la memoria.
2. **Las copias pueden anular la aceleracion.** Con copias hacia y desde los
   buffers, el filtro rojo solo ganaba 1.2-1.4x. El dato debe vivir desde el
   principio en memoria accesible por la DMA.
3. **Con operaciones mas pesadas, el PL se separa.** El Sobel cuesta lo mismo que
   invertir R en el PL (solo mover bytes), mientras que en el PS cuesta ~15 veces
   mas. Resultado: 165x contra el OpenCV de la placa.
4. **Medir con cuidado.** Hubo que corregir varias trampas: la primera corrida en
   frio, las copias dentro del cronometro, el PS leyendo memoria sin cache y un
   OpenCV sin optimizar.
5. **Pipelinear con el handshake.** Avanzar todas las etapas solo cuando hay
   transferencia permite agregar registros para cerrar timing sin romper el
   backpressure; el unico costo es latencia.

## Posibles siguientes pasos

- Compilar OpenCV con NEON para tener la referencia de software mas fuerte posible.
- Aproximar mejor la magnitud con `max + min/2`, sin multiplicadores.
- Manejar los bordes en hardware (replicacion o ceros) para no depender de Python.
- Pasar el ancho por un registro AXI-Lite en lugar de la cabecera.
- Agregar los testbenches a una lista de simulacion de Hog (`.sim`).

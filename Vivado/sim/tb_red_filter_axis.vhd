library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_red_filter_axis is
end entity tb_red_filter_axis;

architecture sim of tb_red_filter_axis is
  constant CLK_PERIOD : time    := 10 ns;
  constant N_WORDS    : integer := 7;   -- 56 bytes: no es multiplo de 3
  constant N_PACKETS  : integer := 3;

  signal aclk    : std_logic := '0';
  signal aresetn : std_logic := '0';

  signal s_tdata  : std_logic_vector(63 downto 0) := (others => '0');
  signal s_tkeep  : std_logic_vector(7 downto 0)  := (others => '0');
  signal s_tlast  : std_logic := '0';
  signal s_tvalid : std_logic := '0';
  signal s_tready : std_logic;

  signal m_tdata  : std_logic_vector(63 downto 0);
  signal m_tkeep  : std_logic_vector(7 downto 0);
  signal m_tlast  : std_logic;
  signal m_tvalid : std_logic;
  signal m_tready : std_logic := '0';

  signal done : boolean := false;
begin
  -- Reloj de 100 MHz, se detiene al terminar
  aclk <= not aclk after CLK_PERIOD / 2 when not done;

  -- Reset activo en bajo durante 5 ciclos
  aresetn <= '0', '1' after 5 * CLK_PERIOD;

  dut : entity work.red_filter_axis
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axis_tdata  => s_tdata,
      s_axis_tkeep  => s_tkeep,
      s_axis_tlast  => s_tlast,
      s_axis_tvalid => s_tvalid,
      s_axis_tready => s_tready,
      m_axis_tdata  => m_tdata,
      m_axis_tkeep  => m_tkeep,
      m_axis_tlast  => m_tlast,
      m_axis_tvalid => m_tvalid,
      m_axis_tready => m_tready
    );

  ---------------------------------------------------------------------------
  -- Emisor (hace de MM2S): byte k del paquete = k, con huecos aleatorios
  ---------------------------------------------------------------------------
  stim : process
    variable seed1 : positive := 1;
    variable seed2 : positive := 2;
    variable r     : real;
  begin
    wait until aresetn = '1';
    wait until rising_edge(aclk);
    for p in 0 to N_PACKETS - 1 loop
      for w in 0 to N_WORDS - 1 loop
        -- Hueco aleatorio antes de la palabra (tvalid = 0)
        uniform(seed1, seed2, r);
        if r < 0.3 then
          s_tvalid <= '0';
          wait until rising_edge(aclk);
        end if;
        for i in 0 to 7 loop
          s_tdata(i*8+7 downto i*8) <= std_logic_vector(to_unsigned((w*8 + i) mod 256, 8));
        end loop;
        s_tkeep  <= (others => '1');
        if w = N_WORDS - 1 then s_tlast <= '1'; else s_tlast <= '0'; end if;
        s_tvalid <= '1';
        -- Espera el handshake (valid y ready en el mismo flanco)
        wait until rising_edge(aclk) and s_tready = '1';
      end loop;
    end loop;
    s_tvalid <= '0';
    s_tlast  <= '0';
    wait;
  end process;

  ---------------------------------------------------------------------------
  -- Backpressure (hace de S2MM): m_tready aleatorio, 70 % en '1'
  ---------------------------------------------------------------------------
  bp : process (aclk)
    variable seed1 : positive := 7;
    variable seed2 : positive := 13;
    variable r     : real;
  begin
    if rising_edge(aclk) then
      uniform(seed1, seed2, r);
      if r < 0.7 then m_tready <= '1'; else m_tready <= '0'; end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Verificador: compara cada palabra de salida con el modelo esperado
  ---------------------------------------------------------------------------
  check : process
    variable k      : integer;
    variable errors : integer := 0;
    variable exp    : std_logic_vector(7 downto 0);
  begin
    for p in 0 to N_PACKETS - 1 loop
      for w in 0 to N_WORDS - 1 loop
        wait until rising_edge(aclk) and m_tvalid = '1' and m_tready = '1';
        for i in 0 to 7 loop
          k   := w*8 + i;
          exp := std_logic_vector(to_unsigned(k mod 256, 8));
          if k mod 3 = 0 then
            exp := not exp;                -- R invertido
          end if;
          if m_tdata(i*8+7 downto i*8) /= exp then
            report "ERROR dato: paquete " & integer'image(p) &
                   " palabra " & integer'image(w) &
                   " byte " & integer'image(i) severity error;
            errors := errors + 1;
          end if;
        end loop;
        if (m_tlast = '1') /= (w = N_WORDS - 1) then
          report "ERROR tlast: paquete " & integer'image(p) &
                 " palabra " & integer'image(w) severity error;
          errors := errors + 1;
        end if;
        if m_tkeep /= x"FF" then
          report "ERROR tkeep: paquete " & integer'image(p) &
                 " palabra " & integer'image(w) severity error;
          errors := errors + 1;
        end if;
      end loop;
    end loop;

    if errors = 0 then
      report "TEST OK: " & integer'image(N_PACKETS * N_WORDS) & " palabras correctas" severity note;
    else
      report "TEST FALLO: " & integer'image(errors) & " errores" severity error;
    end if;
    done <= true;
    wait;
  end process;

  ---------------------------------------------------------------------------
  -- Watchdog: si algo se cuelga, termina con fallo
  ---------------------------------------------------------------------------
  watchdog : process
  begin
    wait for 50 us;
    assert done report "TIMEOUT: la simulacion no termino" severity failure;
    wait;
  end process;

end architecture sim;

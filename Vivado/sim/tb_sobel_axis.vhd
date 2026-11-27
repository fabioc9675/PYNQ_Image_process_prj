library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_sobel_axis is
end entity tb_sobel_axis;

architecture sim of tb_sobel_axis is
  constant CLK_PERIOD : time    := 10 ns;
  constant W          : integer := 32;      -- image width (multiple of 8)
  constant H          : integer := 6;       -- image height
  constant NW         : integer := W / 8;   -- words per row
  constant N_PACKETS  : integer := 2;       -- images sent back to back
  constant N_WORDS    : integer := 1 + H * NW + 3;   -- header + image + 3 padding words

  type img_t is array (0 to H - 1, 0 to W - 1) of integer range 0 to 255;

  -- Pseudo-random test image (simple LCG), different for each seed
  function gen_img(seed : integer) return img_t is
    variable im : img_t;
    variable s  : integer := seed;
  begin
    for y in 0 to H - 1 loop
      for x in 0 to W - 1 loop
        s := (s * 75 + 74) mod 65537;
        im(y, x) := s mod 256;
      end loop;
    end loop;
    return im;
  end function;

  -- Reference model: Sobel |Gx| + |Gy| saturated, centered at (y, x)
  function sobel_ref(im : img_t; y, x : integer) return integer is
    variable gx, gy, mag : integer;
  begin
    gx := (im(y-1, x+1) + 2*im(y, x+1) + im(y+1, x+1))
        - (im(y-1, x-1) + 2*im(y, x-1) + im(y+1, x-1));
    gy := (im(y+1, x-1) + 2*im(y+1, x) + im(y+1, x+1))
        - (im(y-1, x-1) + 2*im(y-1, x) + im(y-1, x+1));
    mag := abs(gx) + abs(gy);
    if mag > 255 then
      mag := 255;
    end if;
    return mag;
  end function;

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
  -- 100 MHz clock, stops when the test is done
  aclk <= not aclk after CLK_PERIOD / 2 when not done;

  -- Active-low reset for 5 cycles
  aresetn <= '0', '1' after 5 * CLK_PERIOD;

  dut : entity work.sobel_axis
    generic map (
      MAX_WORDS => 512
    )
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
  -- Source (acts as MM2S): header, image words, padding word, random gaps
  ---------------------------------------------------------------------------
  stim : process
    variable seed1 : positive := 1;
    variable seed2 : positive := 2;
    variable r     : real;
    variable im    : img_t;
    variable y, x0 : integer;
  begin
    wait until aresetn = '1';
    wait until rising_edge(aclk);
    for p in 0 to N_PACKETS - 1 loop
      im := gen_img(p + 1);
      for k in 0 to N_WORDS - 1 loop
        -- Random idle cycle before the word (tvalid = 0)
        uniform(seed1, seed2, r);
        if r < 0.3 then
          s_tvalid <= '0';
          wait until rising_edge(aclk);
        end if;

        if k = 0 then
          s_tdata <= std_logic_vector(to_unsigned(NW, 64));      -- header: W/8
        elsif k > H * NW then
          s_tdata <= (others => '0');                            -- padding words
        else
          y  := (k - 1) / NW;                                    -- image row
          x0 := ((k - 1) mod NW) * 8;                            -- first column of the word
          for i in 0 to 7 loop
            s_tdata(i*8+7 downto i*8) <= std_logic_vector(to_unsigned(im(y, x0 + i), 8));
          end loop;
        end if;

        s_tkeep <= (others => '1');
        if k = N_WORDS - 1 then s_tlast <= '1'; else s_tlast <= '0'; end if;
        s_tvalid <= '1';
        wait until rising_edge(aclk) and s_tready = '1';         -- handshake
      end loop;
    end loop;
    s_tvalid <= '0';
    s_tlast  <= '0';
    wait;
  end process;

  ---------------------------------------------------------------------------
  -- Backpressure (acts as S2MM): random m_tready, 70 % high
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
  -- Checker: header echo, interior pixels against the model, tlast
  ---------------------------------------------------------------------------
  check : process
    variable im      : img_t;
    variable errors  : integer := 0;
    variable checked : integer := 0;
    variable idx, y, x, got, expected : integer;
  begin
    for p in 0 to N_PACKETS - 1 loop
      im := gen_img(p + 1);
      for k in 0 to N_WORDS - 1 loop
        wait until rising_edge(aclk) and m_tvalid = '1' and m_tready = '1';

        if k = 0 then
          if to_integer(unsigned(m_tdata(15 downto 0))) /= NW then
            report "ERROR header: packet " & integer'image(p) severity error;
            errors := errors + 1;
          end if;
        else
          for i in 0 to 7 loop
            -- Output is delayed by W/8 + 3 words = W + 24 pixels
            idx := (k - 1) * 8 + i - (W + 24);
            if idx >= 0 then
              y := idx / W;
              x := idx mod W;
              -- Only interior pixels are checked (borders are don't care)
              if y >= 1 and y <= H - 2 and x >= 1 and x <= W - 2 then
                expected := sobel_ref(im, y, x);
                got      := to_integer(unsigned(m_tdata(i*8+7 downto i*8)));
                checked  := checked + 1;
                if got /= expected then
                  report "ERROR pixel: packet " & integer'image(p) &
                         " y " & integer'image(y) & " x " & integer'image(x) &
                         " got " & integer'image(got) &
                         " expected " & integer'image(expected) severity error;
                  errors := errors + 1;
                end if;
              end if;
            end if;
          end loop;
        end if;

        if (m_tlast = '1') /= (k = N_WORDS - 1) then
          report "ERROR tlast: packet " & integer'image(p) &
                 " word " & integer'image(k) severity error;
          errors := errors + 1;
        end if;
      end loop;
    end loop;

    -- Every interior pixel must have been checked
    if checked /= N_PACKETS * (H - 2) * (W - 2) then
      report "ERROR: only " & integer'image(checked) & " pixels checked" severity error;
      errors := errors + 1;
    end if;

    if errors = 0 then
      report "TEST OK: " & integer'image(checked) & " pixels" severity note;
    else
      report "TEST FAILED: " & integer'image(errors) & " errors" severity error;
    end if;
    done <= true;
    wait;
  end process;

  ---------------------------------------------------------------------------
  -- Watchdog: fail if the simulation hangs
  ---------------------------------------------------------------------------
  watchdog : process
  begin
    wait for 50 us;
    assert done report "TIMEOUT: simulation did not finish" severity failure;
    wait;
  end process;

end architecture sim;
library ieee;
use ieee.std_logic_1164.all;

entity red_filter_axis is
    port(
        -- clock and reset
        aclk          : in  std_logic;
        aresetn       : in  std_logic;

        -- AXI-Stream input (from DMA, channel MM2S)
        s_axis_tdata  : in  std_logic_vector(63 downto 0);
        s_axis_tkeep  : in  std_logic_vector(7 downto 0);
        s_axis_tlast  : in  std_logic;
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;

        -- AXI-Stream output (to DMA, channel S2MM)
        m_axis_tdata  : out std_logic_vector(63 downto 0);
        m_axis_tkeep  : out std_logic_vector(7 downto 0);
        m_axis_tlast  : out std_logic;
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic
  );
end entity red_filter_axis;  

architecture rtl of red_filter_axis is

    -- aclk is the clock of both AXIS interfaces
    attribute X_INTERFACE_PARAMETER : string;
    attribute X_INTERFACE_PARAMETER of aclk : signal is
        "ASSOCIATED_BUSIF s_axis:m_axis, ASSOCIATED_RESET aresetn";

    -- phase: position of the RGB pattern in the current word
    signal phase   : integer range 0 to 2 := 0;

    -- output registers (internal copy of the m_axis)
    signal data_r  : std_logic_vector(63 downto 0) := (others => '0');
    signal keep_r  : std_logic_vector(7 downto 0)  := (others => '0');
    signal last_r  : std_logic := '0';
    signal valid_r : std_logic := '0';

    -- Indicates if in this cycle we can to accept an entering data
    signal ready_i : std_logic;

    -----------------------------------------------------------------------------
    -- functions
    -- return the word with the R bytes at 0, depends of phase
    function invert_red(data : std_logic_vector(63 downto 0);
                        ph   : integer) return std_logic_vector is
        variable result : std_logic_vector(63 downto 0);
    begin
        result := data;                     -- copy of the word
        for i in 0 to 7 loop                -- run the 8 bytes
            if ((ph + i) mod 3) = 0 then    -- bit i is R?
                result(i*8+7 downto i*8) := not data(i*8+7 downto i*8);   -- R' = 255 - R
            end if;
        end loop;
        return result;
    end function;


begin

    -- can we accept a new data on this cycle?
    ready_i <= (not valid_r) or m_axis_tready;

    -- we connect the signals to the pointers
    s_axis_tready <= ready_i;

    m_axis_tdata  <= data_r;
    m_axis_tkeep  <= keep_r;
    m_axis_tlast  <= last_r;
    m_axis_tvalid <= valid_r;

    process (aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                -- reset: empty registers
                valid_r <= '0';
                data_r  <= (others => '0');
                keep_r  <= (others => '0');
                last_r  <= '0';
                phase   <= 0;
            
            elsif ready_i = '1' then
                -- we can load the output register to the output in this cycle
                valid_r <= s_axis_tvalid;

                if s_axis_tvalid = '1' then
                    -- there is a input handshake, storage the filtered word
                    data_r <= invert_red(s_axis_tdata, phase);
                    keep_r <= s_axis_tkeep;
                    last_r <= s_axis_tlast;

                    -- advance in phase to the next word
                    if s_axis_tlast = '1' then
                        phase <= 0;  -- end of file
                    else
                        phase <= (phase + 2) mod 3;  -- advance to the next word
                    end if;
                end if;
            end if;
        end if;
    end process;

end architecture rtl;

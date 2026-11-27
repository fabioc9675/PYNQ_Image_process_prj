library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sobel_axis is
    generic (
        MAX_WORDS : integer := 512    -- max words per row (512 * 8 = 4096 px)
    );
    port (
        aclk          : in  std_logic;
        aresetn       : in  std_logic;

        s_axis_tdata  : in  std_logic_vector(63 downto 0);
        s_axis_tkeep  : in  std_logic_vector(7 downto 0);
        s_axis_tlast  : in  std_logic;
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;

        m_axis_tdata  : out std_logic_vector(63 downto 0);
        m_axis_tkeep  : out std_logic_vector(7 downto 0);
        m_axis_tlast  : out std_logic;
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic
    );
end entity sobel_axis;

architecture rtl of sobel_axis is
    attribute X_INTERFACE_PARAMETER : string;
    attribute X_INTERFACE_PARAMETER of aclk : signal is
    "ASSOCIATED_BUSIF s_axis:m_axis, ASSOCIATED_RESET aresetn";

    -- Line buffers: one 64-bit word (8 pixels) per address
    type line_t is array (0 to MAX_WORDS - 1) of std_logic_vector(63 downto 0);
    signal lb1 : line_t := (others => (others => '0'));   -- row y-1
    signal lb2 : line_t := (others => (others => '0'));   -- row y-2

    attribute ram_style : string;
    attribute ram_style of lb1 : signal is "distributed";
    attribute ram_style of lb2 : signal is "distributed";

    -- Stream control
    signal hdr_done : std_logic := '0';                       -- '1' after the header word
    signal n_words  : integer range 0 to MAX_WORDS := 0;      -- words per row (W/8)
    signal col      : integer range 0 to MAX_WORDS - 1 := 0;  -- current word in the row

    -- Current block x read from the line buffers (row y comes from s_axis_tdata)
    signal top0, mid0 : std_logic_vector(63 downto 0);

    -- Window history: blocks x-1 and x-2 of the three rows
    signal top1, mid1, bot1 : std_logic_vector(63 downto 0) := (others => '0');
    signal top2, mid2, bot2 : std_logic_vector(63 downto 0) := (others => '0');
    signal top3, mid3, bot3 : std_logic_vector(63 downto 0) := (others => '0');

    -- Output register (same scheme as red_filter_axis)
    signal data_r  : std_logic_vector(63 downto 0) := (others => '0');
    signal keep_r  : std_logic_vector(7 downto 0)  := (others => '0');
    signal last_r  : std_logic := '0';
    signal valid_r : std_logic := '0';
    signal ready_i : std_logic;

    ----------------------------------------------------------------------------    
    -- functions
    -- One row of the window: 10 pixels (last of x-2, 8 of x-1, first of x)
    type row10_t is array (0 to 9) of integer range 0 to 255;
    -- Gradients of the 8 pixels of a block (pipeline stage 1 registers)
    type grad8_t is array (0 to 7) of integer range -1020 to 1020;
    signal gx_r, gy_r : grad8_t := (others => 0);

    function make_row(w2, w1, w0 : std_logic_vector(63 downto 0)) return row10_t is
        variable r : row10_t;
    begin
        r(0) := to_integer(unsigned(w2(63 downto 56)));          -- pixel 7 of block x-2
        for j in 0 to 7 loop
            r(j+1) := to_integer(unsigned(w1(j*8+7 downto j*8)));  -- pixels 0..7 of block x-1
        end loop;
        r(9) := to_integer(unsigned(w0(7 downto 0)));            -- pixel 0 of block x
        return r;
    end function;

        -- Stage 1: horizontal gradient Gx (right column - left column)
    function grad_x(t, m, b : row10_t) return grad8_t is
        variable g : grad8_t;
    begin
        for j in 0 to 7 loop
            g(j) := (t(j+2) + 2*m(j+2) + b(j+2)) - (t(j) + 2*m(j) + b(j));
        end loop;
        return g;
    end function;

    -- Stage 1: vertical gradient Gy (bottom row - top row)
    function grad_y(t, b : row10_t) return grad8_t is
        variable g : grad8_t;
    begin
        for j in 0 to 7 loop
            g(j) := (b(j) + 2*b(j+1) + b(j+2)) - (t(j) + 2*t(j+1) + t(j+2));
        end loop;
        return g;
    end function;

    -- Stage 2: magnitude |Gx| + |Gy|, saturated to 255, packed in 64 bits
    function mag8(gx, gy : grad8_t) return std_logic_vector is
        variable mag    : integer range 0 to 2040;
        variable result : std_logic_vector(63 downto 0);
    begin
        for j in 0 to 7 loop
            mag := abs(gx(j)) + abs(gy(j));
            if mag > 255 then
                mag := 255;                                          -- saturate
            end if;
            result(j*8+7 downto j*8) := std_logic_vector(to_unsigned(mag, 8));
        end loop;
        return result;
    end function;

begin
    -- AXI4-Stream handshake (same scheme as red_filter_axis)
    ready_i       <= (not valid_r) or m_axis_tready;
    s_axis_tready <= ready_i;
    m_axis_tdata  <= data_r;
    m_axis_tkeep  <= keep_r;
    m_axis_tlast  <= last_r;
    m_axis_tvalid <= valid_r;

    -- Asynchronous read of the line buffers (distributed RAM)
    top0 <= lb2(col);   -- block x of row y-2
    mid0 <= lb1(col);   -- block x of row y-1

    process (aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                valid_r  <= '0';
                data_r   <= (others => '0');
                keep_r   <= (others => '0');
                last_r   <= '0';
                hdr_done <= '0';
                n_words  <= 0;
                col      <= 0;
            elsif ready_i = '1' then
                valid_r <= s_axis_tvalid;
                if s_axis_tvalid = '1' then
                    keep_r <= s_axis_tkeep;
                    last_r <= s_axis_tlast;

                    if hdr_done = '0' then
                        -- Header word: W/8 in the low 16 bits, echoed to the output
                        data_r   <= s_axis_tdata;
                        n_words  <= to_integer(unsigned(s_axis_tdata(15 downto 0)));
                        hdr_done <= '1';
                        col      <= 0;
                    else
                        -- (Part 5: image words go here)
                        -- 1) Line buffers: row y-1 moves to y-2, row y is stored as y-1
                        lb2(col) <= mid0;
                        lb1(col) <= s_axis_tdata;

                        -- 2) Sobel of block x-2 of row y-1, in two pipeline stages
                        gx_r <= grad_x(make_row(top3, top2, top1),
                                        make_row(mid3, mid2, mid1),
                                        make_row(bot3, bot2, bot1));
                        gy_r <= grad_y(make_row(top3, top2, top1),
                                        make_row(bot3, bot2, bot1));
                        data_r <= mag8(gx_r, gy_r);    -- uses the gradients of the previous word

                        -- 3) Shift the window history: x-2 -> x-3, x-1 -> x-2, x -> x-1
                        top3 <= top2;  mid3 <= mid2;  bot3 <= bot2;
                        top2 <= top1;  mid2 <= mid1;  bot2 <= bot1;
                        top1 <= top0;  mid1 <= mid0;  bot1 <= s_axis_tdata;

                        -- 4) Next column, wrap at the end of the row
                        if col = n_words - 1 then
                            col <= 0;
                        else
                            col <= col + 1;
                        end if;
                    end if;

                    if s_axis_tlast = '1' then
                        hdr_done <= '0';   -- next packet starts with a new header
                    end if;
                end if;
            end if;
        end if;
    end process;

end architecture rtl;

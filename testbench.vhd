--------------------------------------------------------------------------------
-- testbench.vhd — Лабораторна робота №3, варіант 15 (SPI Master, VHDL)
-- Тестбенч імітує зовнішнє середовище:
--   * генерує тактовий сигнал clk (100 МГц) та скидання rst;
--   * подає тестові байти на вхід передавача (tx_data/start);
--   * містить поведінкову модель SPI Slave, яка приймає MOSI
--     і одночасно передає власні байти по MISO (перевірка Rx);
--   * автоматично порівнює передане/прийняте (assert) і
--     контролює рівень SCK у стані спокою (CPOL).
-- Режим SPI задається генериками G_CPOL / G_CPHA.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_spi_master is
  generic (
    G_CPOL : std_logic := '0';
    G_CPHA : std_logic := '0'
  );
end entity tb_spi_master;

architecture sim of tb_spi_master is

  constant DATA_WIDTH : positive := 8;
  constant CLK_DIV    : positive := 4;          -- SCK = 100 МГц / 8 = 12.5 МГц
  constant CLK_PERIOD : time     := 10 ns;      -- 100 МГц

  -- Тестові вектори: що передає Master і що відповідає Slave
  type byte_arr_t is array (natural range <>) of std_logic_vector(7 downto 0);
  constant MASTER_TX : byte_arr_t := (x"A5", x"3C", x"FF", x"00", x"81", x"5A");
  constant SLAVE_TX  : byte_arr_t := (x"C3", x"96", x"00", x"FF", x"7E", x"12");
  constant N_TESTS   : natural := MASTER_TX'length;

  -- Сигнали DUT
  signal clk      : std_logic := '0';
  signal rst      : std_logic := '1';
  signal start    : std_logic := '0';
  signal tx_data  : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
  signal rx_data  : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal rx_valid : std_logic;
  signal busy     : std_logic;
  signal sck      : std_logic;
  signal mosi     : std_logic;
  signal miso     : std_logic;
  signal ss_n     : std_logic;

  -- Що прийняв Slave (для перевірки передавача)
  signal slave_rx_byte  : std_logic_vector(7 downto 0) := (others => '0');
  signal slave_rx_count : natural := 0;

  signal sim_done : boolean := false;
  signal errors   : natural := 0;

  -- Перетворення байта у рядок з двох hex-символів
  function hex (v : std_logic_vector(7 downto 0)) return string is
    constant DIGITS : string(1 to 16) := "0123456789ABCDEF";
  begin
    if is_x(v) then
      return "XX";
    end if;
    return DIGITS(to_integer(unsigned(v(7 downto 4))) + 1) &
           DIGITS(to_integer(unsigned(v(3 downto 0))) + 1);
  end function hex;

begin

  -- Тестований пристрій (DUT)
  dut : entity work.spi_master
    generic map (
      DATA_WIDTH => DATA_WIDTH,
      CLK_DIV    => CLK_DIV,
      CPOL       => G_CPOL,
      CPHA       => G_CPHA
    )
    port map (
      clk => clk, rst => rst, start => start, tx_data => tx_data,
      rx_data => rx_data, rx_valid => rx_valid, busy => busy,
      sck => sck, mosi => mosi, miso => miso, ss_n => ss_n
    );

  -- Генератор тактового сигналу
  clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

  -- Поведінкова модель SPI Slave (незалежна від коду Master)
  slave_model : process
    variable rx_sh, tx_sh : std_logic_vector(7 downto 0);
    variable idx          : natural := 0;
  begin
    miso <= 'Z';                                -- Slave не вибраний: Z-стан
    wait until ss_n = '0';
    tx_sh := SLAVE_TX(idx mod N_TESTS);
    rx_sh := (others => '0');

    if G_CPHA = '0' then
      miso <= tx_sh(7) after 2 ns;              -- перший біт до першого фронту
    end if;

    for b in 0 to 7 loop
      -- передній фронт (перехід з рівня спокою)
      wait until sck = not G_CPOL;
      if G_CPHA = '0' then
        rx_sh := rx_sh(6 downto 0) & mosi;      -- вибірка
      else
        miso  <= tx_sh(7) after 2 ns;           -- виставлення біта
        tx_sh := tx_sh(6 downto 0) & '0';
      end if;
      -- задній фронт (повернення до рівня спокою)
      wait until sck = G_CPOL;
      if G_CPHA = '0' then
        tx_sh := tx_sh(6 downto 0) & '0';
        miso  <= tx_sh(7) after 2 ns;           -- наступний біт
      else
        rx_sh := rx_sh(6 downto 0) & mosi;      -- вибірка
      end if;
    end loop;

    wait until ss_n = '1';
    slave_rx_byte  <= rx_sh;
    slave_rx_count <= slave_rx_count + 1;
    idx := idx + 1;
  end process slave_model;

  -- Монітор: SCK у стані спокою повинен дорівнювати CPOL
  idle_check : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '0' and ss_n = '1' and sck /= G_CPOL then
        report "SCK idle level /= CPOL while SS_n is high" severity error;
      end if;
    end if;
  end process idle_check;

  -- Стимули та перевірка результатів
  stimulus : process
    variable err : natural := 0;
  begin
    report "=== SPI Master test, mode " &
           integer'image(2*to_integer(unsigned'('0' & G_CPOL)) +
                         to_integer(unsigned'('0' & G_CPHA))) & " ===";
    rst <= '1';
    wait for 5*CLK_PERIOD;
    wait until rising_edge(clk);
    rst <= '0';
    wait for 3*CLK_PERIOD;

    for i in 0 to N_TESTS-1 loop
      -- подати байт і стартовий імпульс
      wait until rising_edge(clk);
      tx_data <= MASTER_TX(i);
      start   <= '1';
      wait until rising_edge(clk);
      start   <= '0';

      -- чекати завершення прийому
      wait until rising_edge(clk) and rx_valid = '1';

      -- перевірка приймача Master (дані від Slave)
      if rx_data /= SLAVE_TX(i) then
        report "RX ERROR #" & integer'image(i) & ": got " &
               hex(rx_data) & ", expected " & hex(SLAVE_TX(i))
               severity error;
        err := err + 1;
      else
        report "RX OK  #" & integer'image(i) & ": master received 0x" &
               hex(rx_data);
      end if;

      -- перевірка передавача Master (дані, прийняті Slave)
      wait for 1 ns;
      if slave_rx_byte /= MASTER_TX(i) or slave_rx_count /= i+1 then
        report "TX ERROR #" & integer'image(i) & ": slave got " &
               hex(slave_rx_byte) & ", expected " &
               hex(MASTER_TX(i)) severity error;
        err := err + 1;
      else
        report "TX OK  #" & integer'image(i) & ": slave  received 0x" &
               hex(slave_rx_byte);
      end if;

      wait for 4*CLK_PERIOD;   -- пауза між кадрами
    end loop;

    errors <= err;
    if err = 0 then
      report "=== TEST PASSED: " & integer'image(N_TESTS) &
             " full-duplex transfers, 0 errors ===";
    else
      report "=== TEST FAILED: " & integer'image(err) & " errors ===" severity error;
    end if;
    sim_done <= true;
    wait;
  end process stimulus;

end architecture sim;

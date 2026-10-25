--------------------------------------------------------------------------------
-- design.vhd — Лабораторна робота №3, варіант 15 (SPI Master, VHDL)
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- 1. ПЕРЕДАВАЧ SPI MASTER (spi_master_tx)
--    FSM, дільник частоти для SCK, керування SS_n, зсувний регістр MOSI.
--    Підтримуються всі чотири режими SPI (CPOL/CPHA). Видає строб
--    sample_en, за яким приймач фіксує біт з лінії MISO.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spi_master_tx is
  generic (
    DATA_WIDTH : positive := 8;      -- розрядність кадру (біт)
    CLK_DIV    : positive := 4;      -- півперіод SCK у тактах clk (>= 2)
                                     -- f_SCK = f_clk / (2 * CLK_DIV)
    CPOL       : std_logic := '0';   -- рівень SCK у стані спокою
    CPHA       : std_logic := '0'    -- 0: вибірка на передньому фронті,
                                     -- 1: вибірка на задньому фронті
  );
  port (
    clk        : in  std_logic;      -- системна тактова частота
    rst        : in  std_logic;      -- синхронне скидання, активний '1'
    -- Інтерфейс користувача
    start      : in  std_logic;      -- імпульс запуску передачі (1 такт)
    tx_data    : in  std_logic_vector(DATA_WIDTH-1 downto 0); -- дані для передачі
    busy       : out std_logic;      -- '1' поки триває транзакція
    done       : out std_logic;      -- імпульс завершення кадру (1 такт)
    -- Сигнали для приймача
    frame_start: out std_logic;      -- імпульс початку кадру (очищення Rx)
    sample_en  : out std_logic;      -- строб вибірки MISO (1 такт)
    -- Лінії шини SPI
    sck        : out std_logic;      -- тактовий сигнал SPI
    mosi       : out std_logic;      -- Master Out Slave In
    ss_n       : out std_logic       -- вибір веденого, активний '0'
  );
end entity spi_master_tx;

architecture rtl of spi_master_tx is

  -- Стани керуючого автомата
  --   IDLE     : очікування команди start, SS_n = '1', SCK = CPOL
  --   TRANSFER : генерація 2*DATA_WIDTH фронтів SCK, зсув даних
  --   STOP     : утримання SS_n = '0' ще півперіоду після останнього фронту
  type state_t is (IDLE, TRANSFER, STOP);
  signal state     : state_t := IDLE;

  -- Внутрішні регістри
  signal div_cnt   : natural range 0 to CLK_DIV-1 := 0;          -- лічильник дільника
  signal edge_cnt  : natural range 0 to 2*DATA_WIDTH-1 := 0;     -- номер фронту SCK
  signal shift_reg : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0'); -- зсувний регістр
  signal sck_r     : std_logic := CPOL;                          -- регістр SCK
  signal mosi_r    : std_logic := '0';                           -- регістр MOSI
  signal ss_n_r    : std_logic := '1';                           -- регістр SS_n
  signal done_r    : std_logic := '0';
  signal sample_r  : std_logic := '0';
  signal fstart_r  : std_logic := '0';

begin

  -- Перевірка параметрів під час елаборації
  assert CLK_DIV >= 2
    report "CLK_DIV must be >= 2 (receiver samples MISO one clk after SCK edge)"
    severity failure;

  -- Основний синхронний процес: FSM + дільник частоти + зсувний регістр
  fsm : process (clk)
    variable leading : boolean;  -- поточний фронт є переднім (першим у біті)
  begin
    if rising_edge(clk) then
      -- імпульсні сигнали за замовчуванням неактивні
      done_r   <= '0';
      sample_r <= '0';
      fstart_r <= '0';

      if rst = '1' then
        state    <= IDLE;
        div_cnt  <= 0;
        edge_cnt <= 0;
        sck_r    <= CPOL;
        ss_n_r   <= '1';
        mosi_r   <= '0';
        shift_reg <= (others => '0');
      else
        case state is

          when IDLE =>
            sck_r  <= CPOL;
            ss_n_r <= '1';
            if start = '1' then
              shift_reg <= tx_data;          -- захоплення даних
              ss_n_r    <= '0';              -- активуємо веденого
              fstart_r  <= '1';
              div_cnt   <= 0;
              edge_cnt  <= 0;
              if CPHA = '0' then
                -- CPHA=0: перший біт має бути на MOSI ДО першого фронту
                mosi_r <= tx_data(DATA_WIDTH-1);
              end if;
              state <= TRANSFER;
            end if;

          when TRANSFER =>
            if div_cnt = CLK_DIV-1 then
              div_cnt <= 0;
              sck_r   <= not sck_r;          -- черговий фронт SCK
              leading := (edge_cnt mod 2 = 0);

              if CPHA = '0' then
                if leading then
                  sample_r <= '1';           -- вибірка на передньому фронті
                else
                  -- зсув і виставлення наступного біта на задньому фронті
                  shift_reg <= shift_reg(DATA_WIDTH-2 downto 0) & '0';
                  mosi_r    <= shift_reg(DATA_WIDTH-2);
                end if;
              else -- CPHA = '1'
                if leading then
                  -- виставлення біта на передньому фронті
                  mosi_r    <= shift_reg(DATA_WIDTH-1);
                  shift_reg <= shift_reg(DATA_WIDTH-2 downto 0) & '0';
                else
                  sample_r <= '1';           -- вибірка на задньому фронті
                end if;
              end if;

              if edge_cnt = 2*DATA_WIDTH-1 then
                state <= STOP;               -- останній фронт кадру
              else
                edge_cnt <= edge_cnt + 1;
              end if;
            else
              div_cnt <= div_cnt + 1;
            end if;

          when STOP =>
            -- витримка півперіоду SCK перед зняттям SS_n
            if div_cnt = CLK_DIV-1 then
              div_cnt <= 0;
              ss_n_r  <= '1';
              done_r  <= '1';
              state   <= IDLE;
            else
              div_cnt <= div_cnt + 1;
            end if;

        end case;
      end if;
    end if;
  end process fsm;

  -- Вихідні сигнали
  sck         <= sck_r;
  mosi        <= mosi_r;
  ss_n        <= ss_n_r;
  done        <= done_r;
  sample_en   <= sample_r;
  frame_start <= fstart_r;
  busy        <= '0' when state = IDLE else '1';

end architecture rtl;

--------------------------------------------------------------------------------
-- 2. ПРИЙМАЧ SPI MASTER (spi_master_rx)
--    Фіксує біти з MISO за стробом sample_en (MSB first). Після кінця кадру
--    (frame_done) переписує слово в rx_data і видає імпульс rx_valid.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spi_master_rx is
  generic (
    DATA_WIDTH : positive := 8               -- розрядність кадру (біт)
  );
  port (
    clk         : in  std_logic;             -- системна тактова частота
    rst         : in  std_logic;             -- синхронне скидання, активний '1'
    miso        : in  std_logic;             -- Master In Slave Out
    frame_start : in  std_logic;             -- початок кадру: очистити регістр
    sample_en   : in  std_logic;             -- строб вибірки біта з MISO
    frame_done  : in  std_logic;             -- кінець кадру: видати дані
    rx_data     : out std_logic_vector(DATA_WIDTH-1 downto 0); -- прийняте слово
    rx_valid    : out std_logic              -- імпульс "дані готові" (1 такт)
  );
end entity spi_master_rx;

architecture rtl of spi_master_rx is

  -- MISO змінюється синхронно з SCK, яку формує сам Master, тож до моменту
  -- вибірки (мінімум 2 такти clk після фронту зміни) сигнал стабільний.
  signal shift_reg : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0'); -- зсувний регістр
  signal data_r    : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0'); -- вихідний регістр
  signal valid_r   : std_logic := '0';

begin

  rx_proc : process (clk)
  begin
    if rising_edge(clk) then
      valid_r <= '0';
      if rst = '1' then
        shift_reg <= (others => '0');
        data_r    <= (others => '0');
      else
        if frame_start = '1' then
          shift_reg <= (others => '0');                      -- новий кадр
        elsif sample_en = '1' then
          shift_reg <= shift_reg(DATA_WIDTH-2 downto 0) & miso; -- зсув вліво, MSB first
        end if;

        if frame_done = '1' then
          data_r  <= shift_reg;                              -- фіксація результату
          valid_r <= '1';
        end if;
      end if;
    end if;
  end process rx_proc;

  rx_data  <= data_r;
  rx_valid <= valid_r;

end architecture rtl;

--------------------------------------------------------------------------------
-- 3. ВЕРХНІЙ РІВЕНЬ SPI MASTER (spi_master)
--    Об'єднує передавач і приймач у дуплексний SPI Master: за одну
--    транзакцію передається tx_data по MOSI і приймається rx_data з MISO.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity spi_master is
  generic (
    DATA_WIDTH : positive  := 8;     -- розрядність кадру
    CLK_DIV    : positive  := 4;     -- f_SCK = f_clk / (2*CLK_DIV); 100 МГц/8 = 12.5 МГц
    CPOL       : std_logic := '0';   -- полярність SCK
    CPHA       : std_logic := '0'    -- фаза SCK
  );
  port (
    clk      : in  std_logic;                                -- системний такт
    rst      : in  std_logic;                                -- скидання, активний '1'
    start    : in  std_logic;                                -- запуск транзакції
    tx_data  : in  std_logic_vector(DATA_WIDTH-1 downto 0);  -- байт для передачі
    rx_data  : out std_logic_vector(DATA_WIDTH-1 downto 0);  -- прийнятий байт
    rx_valid : out std_logic;                                -- прийнятий байт дійсний
    busy     : out std_logic;                                -- транзакція триває
    sck      : out std_logic;
    mosi     : out std_logic;
    miso     : in  std_logic;
    ss_n     : out std_logic
  );
end entity spi_master;

architecture structural of spi_master is
  signal sample_en   : std_logic;   -- строб вибірки MISO
  signal frame_start : std_logic;   -- початок кадру
  signal frame_done  : std_logic;   -- кінець кадру
begin

  u_tx : entity work.spi_master_tx
    generic map (DATA_WIDTH => DATA_WIDTH, CLK_DIV => CLK_DIV,
                 CPOL => CPOL, CPHA => CPHA)
    port map (
      clk => clk, rst => rst, start => start, tx_data => tx_data,
      busy => busy, done => frame_done, frame_start => frame_start,
      sample_en => sample_en, sck => sck, mosi => mosi, ss_n => ss_n
    );

  u_rx : entity work.spi_master_rx
    generic map (DATA_WIDTH => DATA_WIDTH)
    port map (
      clk => clk, rst => rst, miso => miso, frame_start => frame_start,
      sample_en => sample_en, frame_done => frame_done,
      rx_data => rx_data, rx_valid => rx_valid
    );

end architecture structural;

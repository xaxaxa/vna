----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date:    07:44:35 08/31/2017 
-- Design Name: 
-- Module Name:    top - Behavioral 
-- Project Name: 
-- Target Devices: 
-- Tool versions: 
-- Description: 
--
-- Dependencies: 
--
-- Revision: 
-- Revision 0.01 - File Created
-- Additional Comments: 
--
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
library UNISIM;
use UNISIM.VComponents.all;

use work.clk_wiz_v3_6;
use work.ulpi_serial;
use work.dcfifo;
use work.spiDataTx;
use work.slow_clock;
use work.slow_clock_odd;
use work.resetGenerator;
use work.configRegisterTypes.all;
use work.serialConfigRegister;
use work.vnaTxNew;
use work.ejxGenerator;
use work.adf4350_calc;
use work.pulseExtenderCounted;
use work.cic_lpf_2_nd;
use work.ili9341Out;
use work.bounce_sprite;
use work.graphics_types.all;

-- register map:
-- 00: pll_frequency [23..16]
-- 01: pll_frequency [15..8]
-- 02: pll_frequency [7..0]
-- 03: update_trigger; write 1 to update all plls
-- 04: attenuation, in 0.5dB increments
-- 05: 
--   [1..0]: signal generator output power
--   [3..2]: LO output power
--   [5..4]: filter bank select: 00 - no filter, 01 - 110MHz, 10 - 2.5GHz, 11 - 1.1GHz
-- note: the output signal frequency is pll_frequency * 10kHz

entity top2 is
    Port ( CLOCK_19_2 : in  STD_LOGIC;
           LED : out  STD_LOGIC_VECTOR (1 downto 0);
           
           ADF4350_LO_CLK, ADF4350_LO_DATA, ADF4350_LO_LE: out std_logic;
           ADF4350_SG_CLK, ADF4350_SG_DATA, ADF4350_SG_LE: out std_logic;
           
           PE4312_CLK, PE4312_DATA, PE4312_LE: out std_logic;
			  
           ADC0_DATA: in unsigned(9 downto 0);
           ADC0_OTR: in std_logic;
           
           ADC1_DATA: in unsigned(9 downto 0);
           ADC1_OTR: in std_logic;
           
           ADC2_DATA: in unsigned(9 downto 0);
           ADC2_OTR: in std_logic;
           
           BUTTONS: in std_logic_vector(1 downto 0);
           
           RFSW: out std_logic_vector(1 downto 0);
           
           LCD_SCL,LCD_SDI,LCD_CS,LCD_DC,LCD_RST: out std_logic;
			  
           USB_DIR: in std_logic;
			USB_NXT: in std_logic;
			USB_DATA: inout std_logic_vector(7 downto 0);
			USB_RESET_B: out std_logic;
			USB_STP: out std_logic;
			USB_REFCLK: out std_logic);
end top2;

architecture Behavioral of top2 is
	signal internalclk,CLOCK_240,CLOCK_120,CLOCK_60,CLOCK_19_2_i,i2cclk,spiclk,adcclk: std_logic;
	
	signal cnt: unsigned(31 downto 0);
	
	
	--reset
	signal clkgen_en: std_logic := '0';
	signal usbclk: std_logic;
	signal reset: std_logic;
	
	
	--usb serial data
	signal rxval,rxrdy,realrxval,rxclk,txval,txrdy,txclk: std_logic;
	signal rxdat,txdat: std_logic_vector(7 downto 0);
	signal usbtxval,usbtxrdy,usbrxval,usbrxrdy: std_logic;
	signal usbtxdat,usbrxdat: std_logic_vector(7 downto 0);
	signal txroom: unsigned(13 downto 0);
	signal tmp: unsigned(7 downto 0);
	signal led_usbserial: std_logic;
	signal usb_txcork: std_logic;
	
	signal fifo1empty,fifo1full: std_logic;
	
	-- adf4350 config
	signal config_freq: unsigned(19 downto 0);				-- configured sgen frequency (10kHz increments)
	signal lo_freq: unsigned(19 downto 0);
	signal odiv: unsigned(5 downto 0);						-- rf divide factor
	
	signal pll1_R, pll2_R: std_logic_vector(9 downto 0);
	signal pll1_mod, pll2_mod: std_logic_vector(11 downto 0);
	signal pll1_N, pll2_N: std_logic_vector(15 downto 0);
	signal pll1_frac, pll2_frac: std_logic_vector(11 downto 0);
	signal pll1_O, pll2_O: std_logic_vector(2 downto 0);
	signal pll1_pwr, pll2_pwr: std_logic_vector(1 downto 0);
	--signal adf4350_clk,adf4350_le,adf4350_data: std_logic;
	signal pll_update_usbclk, pll_update1, pll_update2, pll_update3, pll_do_update: std_logic;
	
	-- pe4312 config
	signal pe4312_attenuation: unsigned(5 downto 0);
	
	-- adc
	signal adc0_data1, adc1_data1, adc2_data1: unsigned(9 downto 0);
	signal data0, data1, data2: signed(9 downto 0);
	signal filtered0, filtered1, filtered2: signed(17 downto 0);
	signal adc_overflows: std_logic_vector(2 downto 0);
	signal adc_overflow, adc_overflow_ignore: std_logic;
	signal pll_update1_adcclk, pll_update2_adcclk, pll_update3_adcclk, pll_do_update_adcclk: std_logic;
	
	-- sine generator
	signal sg_re,sg_im: signed(8 downto 0);
	
	--vna tx data
	signal vna_txdat: std_logic_vector(7 downto 0);
	signal vna_txval: std_logic;
	
	-- config registers
	constant cfgCount: integer := 6;
	signal cfg: array8(0 to cfgCount-1);
	signal cfg_wrIndicate: std_logic;
	signal cfg_wrAddr: unsigned(7 downto 0);
	-- how long to ignore adc overflow for after a pll reconfig; in adcclk cycles
	constant adc_ignore_overflow_duration: integer := 19200;
	
	-- ui
	signal use_vna_txdat: std_logic;
	signal led_adc_overflow: std_logic;
	
	
	-- lcd user side interface signals
	signal lcdClk: std_logic;
	signal lcd_scl1,lcd_sdi1,lcd_cs1,lcd_dc1: std_logic;
	signal curPos: position;
	signal pixel,pixelOut: color;
	
	--sprite position control
	signal spritePos: position;
	signal spriteAdvance: std_logic;
	
	constant W: integer := 240;
	constant H: integer := 320;
	constant spriteW,spriteH: integer := 50;
	
begin
	--############# CLOCKS ##############

	pll: entity clk_wiz_v3_6 port map(
		CLK_IN1=>CLOCK_19_2,
		CLK_OUT1=>CLOCK_60,
		CLK_OUT2=>CLOCK_120,
		CLK_OUT3=>CLOCK_240,
		CLK_OUT4=>CLOCK_19_2_i,
		LOCKED=>open);
	INST_STARTUP: STARTUP_SPARTAN6
        port map(
         CFGCLK => open,
         CFGMCLK => internalclk,
         CLK => '0',
         EOS => open,
         GSR => '0',
         GTS => '0',
         KEYCLEARB => '0');
	usbclk <= CLOCK_60;
	adcclk <= CLOCK_19_2_i;
	-- 250kHz state machine clock => 62.5kHz i2c clock
	i2cc: entity slow_clock generic map(200,100) port map(internalclk,i2cclk);
	-- 2MHz spi clock
	spic: entity slow_clock generic map(26,13) port map(internalclk,spiclk);
	
	--############# usb serial port device ##############
	usbdev: entity ulpi_serial generic map(minTxSize=>300) port map(USB_DATA, USB_DIR, USB_NXT,
		USB_STP, open, usbclk, usbrxval,usbrxrdy,usbtxval,usbtxrdy, usbrxdat,usbtxdat,
		LED=>led_usbserial, txroom=>txroom, txcork=>'0');
	USB_RESET_B <= '1';
	outbuf: ODDR2 generic map(DDR_ALIGNMENT=>"NONE",SRTYPE=>"SYNC")
		port map(C0=>usbclk, C1=>not usbclk,CE=>'1',D0=>'1',D1=>'0',Q=>USB_REFCLK);
	
	-- fifos
	fifo1: entity dcfifo generic map(8,13) port map(usbclk,txclk,
		usbtxval,usbtxrdy,usbtxdat,open,
		txval,txrdy,txdat,open);
	
	txval <= vna_txval when use_vna_txdat='1' else '1';
	txclk <= adcclk;
	txdat <= std_logic_vector(filtered0(17 downto 10)) when use_vna_txdat='0' and BUTTONS="00"
			else std_logic_vector(filtered1(17 downto 10)) when use_vna_txdat='0' and BUTTONS="01"
			else std_logic_vector(filtered2(17 downto 10)) when use_vna_txdat='0' and BUTTONS="10"
			else vna_txdat;
	
	
	pll_update1 <= pll_update_usbclk when rising_edge(spiclk);
	pll_update2 <= pll_update1 when rising_edge(spiclk);
	pll_update3 <= pll_update2 when rising_edge(spiclk);
	pll_do_update <= pll_update2 xor pll_update3 when rising_edge(spiclk);
	
	
	-- adf4350 spi
	lo_freq <= config_freq+70;
	pll1_pwr <= cfg(5)(3 downto 2);
	pll2_pwr <= cfg(5)(1 downto 0);
	
	
	calc1: entity adf4350_calc generic map(1920) port map(usbclk, lo_freq, pll1_N, pll1_frac, pll1_O);
	calc2: entity adf4350_calc generic map(1920) port map(usbclk, config_freq, pll2_N, pll2_frac, pll2_O);
	
	--pll2_R <= std_logic_vector(to_unsigned(26,10));
	pll1_R <= std_logic_vector(to_unsigned(1,10));
	pll1_mod <= std_logic_vector(to_unsigned(1920,12));
	--pll2_N <= std_logic_vector(to_unsigned(3026,16));
	--pll1_N <= std_logic_vector(to_unsigned(190,16));
	--pll1_N <= cfg(0) & cfg(1);
	--pll1_frac <= std_logic_vector(to_unsigned(0,12));
	
	pll2_R <= pll1_R;
	pll2_mod <= pll1_mod;
	--pll2_N <= pll1_N;
	--pll2_frac <= std_logic_vector(to_unsigned(16,12));
	spi1: entity spiDataTx generic map(words=>6,wordsize=>32) port map(
	--	 XXXXXXXXLLXXXXXXXXXXXXXXXXXXX101
		"00000000010000000000000000000101" &
	--	 XXXXXXXXF    OOO   BBBBBBBBVMAA    AA          R    OO          100
		"000000001"&pll1_O&"111111110001" & pll1_pwr & "1" & pll1_pwr & "100" &
		"00000000000000000" & std_logic_vector(to_unsigned(80,12)) & "011" &
		"01100100" & pll1_R & "01111101000010" &
		"00001000000000001" & pll1_mod & "001" &
		"0" & pll1_N & pll1_frac & "000",
		spiclk, reset or pll_do_update, ADF4350_LO_CLK, ADF4350_LO_LE, ADF4350_LO_DATA);
	
	spi2: entity spiDataTx generic map(words=>6,wordsize=>32) port map(
	--	 XXXXXXXXLLXXXXXXXXXXXXXXXXXXX101
		"00000000010000000000000000000101" &
	--	 XXXXXXXXF    OOO   BBBBBBBBVMAAAAR    OO          100
		"000000001"&pll2_O&"111111110000001" & pll2_pwr & "100" &
		"00000000000000000" & std_logic_vector(to_unsigned(80,12)) & "011" &
		"01100100" & pll2_R & "01111101000010" &
		"00001000000000001" & pll2_mod & "001" &
		"0" & pll2_N & pll2_frac & "000",
		spiclk, pll_do_update, ADF4350_SG_CLK, ADF4350_SG_LE, ADF4350_SG_DATA);
	
	spi3: entity spiDataTx generic map(words=>1,wordsize=>6) port map(
		std_logic_vector(pe4312_attenuation),
		spiclk, pll_do_update, PE4312_CLK, PE4312_LE, PE4312_DATA);

	
	-- config registers
	cfgInst: entity serialConfigRegister generic map(bytes=>cfgCount, defaultValue =>
		(X"00", X"00", std_logic_vector(to_unsigned(190, 8)), X"00", X"00", "00001100", others=>X"00"))
		port map(usbclk, usbrxdat, usbrxval, cfg, cfg_wrIndicate, cfg_wrAddr);
	usbrxrdy <= '1';
	config_freq <= unsigned(cfg(0)(3 downto 0)) & unsigned(cfg(1)) & unsigned(cfg(2));
	pll_update_usbclk <= not pll_update_usbclk when cfg_wrIndicate='1' and cfg_wrAddr=X"03" and rising_edge(usbclk);
	pe4312_attenuation <= unsigned(cfg(4)(5 downto 0));
	
	
	-- vna data
	sg: entity ejxGenerator port map(adcclk,to_unsigned(9786709,28),sg_re,sg_im);
	vnaTx1: entity vnaTxNew generic map(adcBits=>14) port map(adcclk,
		filtered0(17 downto 4),filtered1(17 downto 4),filtered2(17 downto 4), sg_im,sg_re, vna_txdat, vna_txval);
	txclk <= adcclk;
	
	-- adcs
	adc0_data1 <= ADC0_DATA when rising_edge(adcclk);
	adc1_data1 <= ADC1_DATA when rising_edge(adcclk);
	adc2_data1 <= ADC2_DATA when rising_edge(adcclk);
	data0 <= signed(adc0_data1+"1000000000") when rising_edge(adcclk);
	data1 <= signed(adc1_data1+"1000000000") when rising_edge(adcclk);
	data2 <= signed(adc2_data1+"1000000000") when rising_edge(adcclk);
	adc_overflows <= ADC2_OTR & ADC1_OTR & ADC0_OTR when rising_edge(adcclk);
	adc_overflow <= adc_overflows(0) or adc_overflows(1) or adc_overflows(2) when rising_edge(adcclk);
	
	-- overflow detection
	pll_update1_adcclk <= pll_update_usbclk when rising_edge(adcclk);
	pll_update2_adcclk <= pll_update1_adcclk when rising_edge(adcclk);
	pll_update3_adcclk <= pll_update2_adcclk when rising_edge(adcclk);
	pll_do_update_adcclk <= pll_update2_adcclk xor pll_update3_adcclk when rising_edge(adcclk);
	pe1: entity pulseExtenderCounted generic map(adc_ignore_overflow_duration)
		port map(adcclk, pll_do_update_adcclk, adc_overflow_ignore);
	pe2: entity pulseExtenderCounted generic map(192000) port map(adcclk, adc_overflow and not adc_overflow_ignore, led_adc_overflow);

	-- filters
	filt0: entity cic_lpf_2_nd generic map(inbits=>10, outbits=>18, stages=>5, bw_div=>3)
		port map(adcclk, data0, filtered0);
	filt1: entity cic_lpf_2_nd generic map(inbits=>10, outbits=>18, stages=>5, bw_div=>3)
		port map(adcclk, data1, filtered1);
	filt2: entity cic_lpf_2_nd generic map(inbits=>10, outbits=>18, stages=>5, bw_div=>3)
		port map(adcclk, data2, filtered2);

	cnt <= cnt+1 when rising_edge(CLOCK_19_2_i);
	LED <= led_usbserial & led_adc_overflow;
	
	rg: entity resetGenerator generic map(25000) port map(spiclk,reset);
	
	
	-- ui
	use_vna_txdat <= BUTTONS(0) and BUTTONS(1);
	
	
	RFSW <= cfg(5)(5 downto 4);
	
	
	
	
	-- ############### lcd ###############
	
	-- 48MHz
	sc: entity slow_clock_odd generic map(5,2) port map(CLOCK_240,lcdClk);
	
	-- lcd controller
	lcdOut: entity ili9341Out generic map(2) port map(lcdClk,curPos,
		pixelOut, lcd_scl1,lcd_sdi1,lcd_cs1,lcd_dc1,open);
	
	lcdBuf: ODDR2 generic map(DDR_ALIGNMENT=>"NONE",SRTYPE=>"SYNC")
		port map(C0=>lcd_scl1, C1=>not lcd_scl1,CE=>'1',D0=>'1',D1=>'0',Q=>LCD_SCL);
	--LCD_SCL <= lcd_scl1;
	LCD_SDI <= lcd_sdi1 when falling_edge(lcdclk);
	LCD_CS <= lcd_cs1 when falling_edge(lcdclk);
	LCD_DC <= lcd_dc1 when falling_edge(lcdclk);
	
	
	-- draw the rectangle
	pixel <= (X"ff",X"00",X"00") when curPos(0)>spritePos(0) and curPos(0)<spritePos(0)+spriteW
			and curPos(1)>spritePos(1) and curPos(1)<spritePos(1)+spriteH
		else (X"ff",X"ff",X"00") when curPos(0)=0 or curPos(1)=0 or curPos(0)=W-1 or curPos(1)=H-1
		else (X"00",X"00",X"00");
	pixelOut <= pixel when rising_edge(lcdClk);
	
	--calculate the position of the rectangle
	spriteAdvance <= '1' when curPos(0)=0 and curPos(1)=0 else '0';
	bounce: entity bounce_sprite generic map(W,H,spriteW,spriteH)
		port map(lcdClk, spriteAdvance, spritePos, to_unsigned(6,15), to_unsigned(6,15));
	
end Behavioral;


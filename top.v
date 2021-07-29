`default_nettype none
`timescale 1ns / 1ps

// I2S (inter-IC Sound bus) master
//
// tested with PCM5102A
//
// note: this is very rough and ready.  currently it will sample SMP twice,
//       at different phases for the left and right channels. this creates
//       a stereo effect and should be fixed.
//
module i2s_master_t(
      input CLK,          // 12Mhz input clock
      input [15:0] SMP,   // input sample data (twos-compliment format)
      output SCK,
      output BCK,
      output DIN,
      output LCK          // ~48Khz
      );

  reg [ 8:0] counter;
  reg [15:0] shift;
  reg out;

  assign SCK = CLK;           // (sck)           12 Mhz
  assign BCK = counter[1];    // (sck / 4)        3 Mhz
  assign LCK = counter[7];    // (sck / 256)  46875 Hz
  assign DIN = shift[15];     // (sck / 4)        3 Mhz

  initial begin
    counter <= 'd0;
    shift <= 'd0;
  end

  always @(posedge CLK) begin
    // on the falling edge of BCK
    if (counter[1:0] == 0) begin
      if (counter[6:2] == 1) begin
        // re-sample at on BCK after LRCK edge
        shift <= SMP;
      end else begin
        // shift out data
        shift <= { shift[14:0], 1'b0 };
      end
    end
    counter <= counter + 'd1;
  end
endmodule

// very simple UART receiver 
module uart_rx(input clk,
               input rx,
               output reg [7:0] data,
               output reg recv);

  // ICESUGARNANO baudrates (12Mhz)
  //   9600 - 1250
  //  19200 -  625
  localparam CLK_RATE = 12000000;
  localparam BAUD = 9600;
  localparam CLK_DIV = CLK_RATE / BAUD;

  reg [10:0] clk_count;   // (2048 max)
  reg [3:0] count;        // (  16 max)
  reg rx_;

  initial begin
    clk_count <= 0;
    data      <= 0;
    count     <= 0;  // idle state
    rx_       <= 1;
    recv      <= 0;
  end

  always @(posedge clk) begin
    // if we are idle
    if (count == 0) begin
      // if start bit has been detected
      if (rx_ == 1 && rx == 0) begin
        // set clock count to 1/2 clk_div so we start samping half way
        // through the data cycle
        clk_count <= CLK_DIV / 2;
        // 8 bits + start bit
        count <= 9;
      end
    end else begin
      // time to sample the data
      if (clk_count == 0) begin
        // shift the data in
        data <= { rx, data[7:1] };
        // reduce count by one
        count <= count - 1;
        // prime the next counter
        clk_count <= CLK_DIV;
      end else begin
        clk_count <= clk_count - 1;
      end
    end
    // update the edge detector
    rx_ = rx;
  end

  always @(posedge clk) begin
    // if we have just sampled our last bit
    if (count == 1 && clk_count == 0) begin
      recv = 1;
    end else begin
      recv = 0;
    end
  end
endmodule

// 12Mhz to 1Mhz gate generator
module sid_clock(input CLK, output CLK1);
  reg [11:0] shift;
  assign CLK1 = shift[0];
  initial begin
    shift = 'h001;
  end
  always @(posedge CLK) begin
    // rotate left
    shift <= { shift[10:0], shift[11] };
  end
endmodule

module top(input CLK, input RX, output [7:0] PM3);

  // note: currently the SID outputs at 1Mhz but is being sampled at around
  //       44Khz this it will alias a lot. on the todo list is a low-pass
  //       filter to remove frequencies > 22Khz. This should be done prior to
  //       I2C conversion.

  // instanciate the uart receiver
  reg [7:0] data;
  reg recv;
  uart_rx uart(
    .clk(CLK),
    .rx(RX),
    .data(data),
    .recv(recv));

  // instanciate sid clock gate generator
  reg sid_tick;
  sid_clock sid_clk(
    .CLK(CLK),
    .CLK1(sid_tick));

  // instanciate the SID
  reg [15:0] sid_out;
  sid psg(
    .CLK(CLK),
    .TICK(sid_tick),
    .WR(wr),
    .ADDR(laddr),
    .DATA(ldata),
    .OUTPUT(sid_out));

  reg SCK;
  reg LRCLK;
  reg DATA;
  reg BCLK;
  assign PM3[0] = SCK;
  assign PM3[1] = BCLK;
  assign PM3[2] = DATA;
  assign PM3[3] = LRCLK;

  // note: shift signal down a bit so its not too loud (~2vac)
  wire [15:0] VAL = { {3{sid_out[15]}}, sid_out[14:2] };

  // instanciate the I2S encoder
  i2s_master_t i2s(
    .CLK(CLK),
    .SMP(VAL),
    .SCK(SCK),
    .BCK(BCLK),
    .DIN(DATA),
    .LCK(LRCLK));

  reg [4:0] laddr;  // latched address
  reg [7:0] ldata;  // latched data
  reg wr;           // write signal

  // input data decoder
  //
  // receive format:
  //    1AAA AADD   - address, data MSB
  //    0?DD DDDD   -          data LSB
  //
  always @(posedge CLK) begin
    if (recv) begin
      if (data[7] == 'b1) begin
        wr <= 0;
        laddr <= data[6:2];
        ldata <= { data[1:0], ldata[5:0] };
      end else begin
        wr <= 1;
        ldata <= { ldata[7:6], data[5:0] };
      end
    end else begin
      wr <= 0;
    end
  end
endmodule

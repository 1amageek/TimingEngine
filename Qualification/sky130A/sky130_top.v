module top (clk, d, q);
  input clk;
  input d;
  output q;
  sky130_fd_sc_hd__dfxtp_1 u0 (
    .CLK(clk),
    .D(d),
    .Q(q)
  );
endmodule

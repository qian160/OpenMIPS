module div32_tb(

);

    reg clk;
    reg rst = 0;
    reg [31:0] a;
    reg [31:0] b;

    reg start = 1;
    reg done = 0;
    wire done_t = 0;
    wire [31:0] c;
    wire [31:0] d;

    reg [31:0] cc,dd;
    div32 ddd(clk,rst,start,a,b,done_t,c,d);

    assign done_t = done;

    initial begin
        a = 32'd43;
        b = 32'd7;
	done = 0;
    end

	initial begin
        clk = 0;
        forever #10 clk = ~clk;
    end
endmodule
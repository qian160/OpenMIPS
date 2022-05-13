`include"def.v"
module regfile(
	input wire clk,
	input wire rst,
	// 写端口
	input wire we,
	input wire[` RegAddrBus] waddr,	//which reg to write,4:0
	input wire[` RegBus] wdata,  //31:0
	// 读端口1
	input wire re1,			//使能信号
	input wire[` RegAddrBus] raddr1,
	output reg[` RegBus] rdata1,
	// 读端口2
	input wire re2,
	input wire[` RegAddrBus] raddr2,
	output reg[` RegBus] rdata2
);

//定义32个32位寄存器
reg[` RegBus] regs[0:` RegNum-1];

//写操作
always @ (posedge clk) begin
	if (rst == ` RstDisable) begin
		if((we == ` WriteEnable) && (waddr != ` RegNumLog2'h0)) begin //the 1st reg is always 0,and should't be write
			regs[waddr] <= wdata;
		end
	end
end

//读端口1的读操作
always @ (*) begin
	if(rst == ` RstEnable) begin
		rdata1 <= ` ZeroWord;
	end
	else if(raddr1 == ` RegNumLog2'h0) begin
		rdata1 <= ` ZeroWord;
	end 
	else if((raddr1 == waddr) && (we == ` WriteEnable)&& (re1 == ` ReadEnable)) begin
		rdata1 <= wdata;	//如果要读取的寄存器是在下一个时钟上升沿要写入的寄存器，那么就将要写入的数据直接作为结果输出
	end 
	else if(re1 == ` ReadEnable) begin
		rdata1 <= regs[raddr1];
	end 
	else begin		//maybe sth goes wrong.default case
		rdata1 <= ` ZeroWord;
	end
end

//读端口2的读操作
always @ (*) begin
	if(rst == ` RstEnable) begin
		rdata2 <= ` ZeroWord;
	end 
	else if(raddr2 == ` RegNumLog2'h0) begin
		rdata2 <= ` ZeroWord;
	end 
	else if((raddr2 == waddr) && (we == ` WriteEnable) && (re2 == ` ReadEnable)) begin
		rdata2 <= wdata;
	end 
	else if(re2 == ` ReadEnable) begin
		rdata2 <= regs[raddr2];
	end 
	else begin
		rdata2 <= ` ZeroWord;
	end
end
endmodule
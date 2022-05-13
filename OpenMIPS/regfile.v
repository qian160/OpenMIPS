`include"def.v"
module regfile(
	input wire clk,
	input wire rst,
	// д�˿�
	input wire we,
	input wire[` RegAddrBus] waddr,	//which reg to write,4:0
	input wire[` RegBus] wdata,  //31:0
	// ���˿�1
	input wire re1,			//ʹ���ź�
	input wire[` RegAddrBus] raddr1,
	output reg[` RegBus] rdata1,
	// ���˿�2
	input wire re2,
	input wire[` RegAddrBus] raddr2,
	output reg[` RegBus] rdata2
);

//����32��32λ�Ĵ���
reg[` RegBus] regs[0:` RegNum-1];

//д����
always @ (posedge clk) begin
	if (rst == ` RstDisable) begin
		if((we == ` WriteEnable) && (waddr != ` RegNumLog2'h0)) begin //the 1st reg is always 0,and should't be write
			regs[waddr] <= wdata;
		end
	end
end

//���˿�1�Ķ�����
always @ (*) begin
	if(rst == ` RstEnable) begin
		rdata1 <= ` ZeroWord;
	end
	else if(raddr1 == ` RegNumLog2'h0) begin
		rdata1 <= ` ZeroWord;
	end 
	else if((raddr1 == waddr) && (we == ` WriteEnable)&& (re1 == ` ReadEnable)) begin
		rdata1 <= wdata;	//���Ҫ��ȡ�ļĴ���������һ��ʱ��������Ҫд��ļĴ�������ô�ͽ�Ҫд�������ֱ����Ϊ������
	end 
	else if(re1 == ` ReadEnable) begin
		rdata1 <= regs[raddr1];
	end 
	else begin		//maybe sth goes wrong.default case
		rdata1 <= ` ZeroWord;
	end
end

//���˿�2�Ķ�����
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
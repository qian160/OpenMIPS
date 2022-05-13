`include"def.v"
module if_id(
	input wire 					clk,
	input wire 					rst,
	//来自取指阶 段的信号，其中宏定义InstBus表示指令宽度，为32
	input wire[`InstAddrBus] 	if_pc,
	input wire[`InstBus] 		if_inst,
	input wire [5:0] 			stall,

	input wire     				flush,

	//对应译码阶 段的信号
	output reg[`InstAddrBus] 	id_pc,
	output reg[`InstBus] 		id_inst
);
	always @ (posedge clk) begin
		if (rst == `RstEnable) begin
			id_pc <= `ZeroWord; 
			id_inst <= `ZeroWord; 
		end

		//（1）当stall[1]为Stop，stall[2]为NoStop时，表示取指阶 段暂停，
		// 而译码阶 段继续，所以使用空指令作为下一个周期进入译码阶 段的指令
		//（2）当stall[1]为NoStop时，取指阶 段继续，取得的指令进入译码阶 段
		//（3）其余情况下，保持译码阶 段的寄存器id_pc、id_inst不变

		if(flush == 1'b1)  begin
				id_pc <= `ZeroWord;
				id_inst <=`ZeroWord;
		end

		else if(stall[1] == `Stop && stall[2] == `NoStop) begin
			id_pc <= `ZeroWord;		//stop inst fetch,give empty inst
			id_inst <= `ZeroWord;
		end 
		else if(stall[1] == `NoStop) begin		
			id_pc <= if_pc;
			id_inst <= if_inst;
		end
	end
endmodule
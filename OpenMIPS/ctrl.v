`include"def.v"
module ctrl(
	input wire 					rst,
	input wire 					stallreq_from_id,

	input wire[31:0]            excepttype_i,
	input wire[`RegBus]         cp0_epc_i,

	output reg[`RegBus]         new_pc,		//exception handler's entry
	output reg                  flush,	
	input wire 					stallreq_from_ex, 
	output reg[5:0] 			stall
);

	/*
			stall[0] to stall[6] stands for pc's value,if, id, ex, mem, wb
		when stage n ask for a stall,stage 0,1, ... n-1 should stop get new things
		
			realize that stall means "I'm busy doing my work now, please don't send new job to me" 
		instead of "I will do nothing now".
		
			for example, when ex is stalled, ex is still busy doing it's work,
		but ID/EX will not deliver new work to it.And since id/ex holds that value,it can't be covered by the previous stage
		so the previous stage should also be stalled
	*/
	always @ (*) begin
		if(rst == ` RstEnable) begin
			stall <= 6'b000000;
			flush <= 1'b0;
			new_pc <= `ZeroWord;
		end 
		//不为0，发生了异常
		//跳转到异常处理例程的入口
		else if(excepttype_i != `ZeroWord) begin
		  	flush <= 1'b1;			//清除流水线
		  	stall <= 6'b000000;
			case (excepttype_i)
				32'h00000001:   begin   //interrupt
					new_pc <= 32'h00000020;
				end
				32'h00000008:   begin   //syscall
					new_pc <= 32'h00000040;
				end
				32'h0000000a:   begin   //inst_invalid
					new_pc <= 32'h00000040;
				end
				32'h0000000d:   begin   //trap，自陷
					new_pc <= 32'h00000040;
				end
				32'h0000000c:   begin   //ov
					new_pc <= 32'h00000040;
				end
				32'h0000000e:   begin   //eret
					new_pc <= cp0_epc_i;
				end
				default	: begin
				end
			endcase 						
		end 
		//okay, no exception
		//but stall may also exist, so go check it
		else if(stallreq_from_ex == `Stop) begin
			//pc,if,id,ex
			stall <= 6'b001111;
			flush <= 1'b0;
		end 
		else if(stallreq_from_id == `Stop) begin
			//pc,if,id
			stall <= 6'b000111;
			flush <= 1'b0;
		end 
		//no exception and no stall
		else begin
			stall <= 6'b000000;
			flush <= 1'b0;
			new_pc <= `ZeroWord;
		end
	end
endmodule
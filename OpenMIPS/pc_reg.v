`include"def.v"
module pc_reg(
		input wire 					clk,
		input wire 					rst,
		input wire [5:0] 			stall,

		input wire 					flush,
		input wire[`RegBus]			new_pc,		//异常处理例程的地址

		input wire 					branch_flag_i,
		input wire [`RegBus]		branch_target_address_i,
		output reg[`InstAddrBus] 	pc,
		output reg 					ce
);

	always @ (posedge clk) begin
		if (rst == `RstEnable) begin
				ce <= `ChipDisable; // 
		end
		else begin
				ce <= `ChipEnable; // 
		end
	end

	always @ (posedge clk) begin
		if (ce == `ChipDisable) begin
				pc <= 32'h00000000; // 
		end
		else begin
			if (flush == 1'b1)  begin
					pc <= new_pc;		//exception occurs, new_pc points to the exception handle entry
			end

			else if(stall[0] == `NoStop)  begin
				if(branch_flag_i == `Branch) begin
					pc <= branch_target_address_i;
				end
				else begin
					pc <= pc + 4'h4; 	//normal case, go to fetch next instruction
				end
			end
		end
	end

endmodule

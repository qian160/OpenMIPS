`include"def.v"
module ex_mem(
	input wire 		clk,
	input wire 		rst,
	// 来自执行阶段的信息
	input wire [`RegAddrBus] 		ex_wd,
	input wire 						ex_wreg,
	input wire [`RegBus] 			ex_wdata,

	input wire [`RegBus]           	ex_hi,
	input wire [`RegBus]           	ex_lo,
	input wire                    	ex_whilo, 

	input wire [5:0] 				stall,

	input wire [`AluOpBus]			ex_aluop,
	input wire [`RegBus]			ex_mem_addr,
	input wire [`RegBus]			ex_reg2,

	input wire   					flush,
	input wire[`RegBus]             ex_excepttype,
	input wire                   	ex_is_in_delayslot,			
	//WHEN A DELAY SLOT INSTRUCTION CAUSES A EXCEPTION, THE EPC SHOULD BE PC - 4. SO WHEN RETURNED THE BRANCH WOULD BE TAKEN AGAIN
	/*
		the instruction flow we except:
			branch -> delay slot -> branch target
		if we set epc = pc, then the actual instruction flow would be:
			branch -> delay slot -> delay slot + 1 -> ......
	*/
	input wire[`RegBus]          	ex_current_inst_address,

	output reg[31:0]            	mem_excepttype,
  	output reg                		mem_is_in_delayslot,
	output reg[`RegBus]         	mem_current_inst_address,

	output reg [`AluOpBus]			mem_aluop,
	output reg [`RegBus]			mem_addr,
	output reg [`RegBus]			mem_reg2,
	// 送到访存阶段的信息
	output reg [`RegAddrBus] 		mem_wd,
	output reg 						mem_wreg,
	output reg [`RegBus]		 	mem_wdata,
	output reg [`RegBus]          	mem_hi,
	output reg [`RegBus]          	mem_lo,
	output reg                   	mem_whilo,
	
	input wire                   	ex_cp0_reg_we,
	input wire[4:0]              	ex_cp0_reg_write_addr,
	input wire[`RegBus]          	ex_cp0_reg_data,

	output reg                   	mem_cp0_reg_we,
	output reg[4:0]              	mem_cp0_reg_write_addr,
	output reg[`RegBus]          	mem_cp0_reg_data,
	//多周期指令
	input wire[`DoubleRegBus] 		hilo_i,
	input wire[1:0]			 		cnt_i,
	output reg [`DoubleRegBus] 		hilo_o,
	output reg [1:0] 				cnt_o
);

	//1.执行阶段(stall3)暂停，而访存阶段(stall4)继续，所以使用空指令作为下一个周期进入访存阶 段的指令
	//2.执行阶 段继续，执行后的指令进入访存阶段
	//3.其余情况下，保持访存阶段的寄存器不变

	//在流水线执行阶段暂停的时候，说明遇到多周期指令了。这时就是那些特殊的端口输入进来的数据发挥作用的时候了。
	//将输入信号hilo_i通过输出接口hilo_o送出，
	//输入信号cnt_i通过输出接口cnt_o送出。其余时刻，hilo_o为0，cnt_o也为0
	 always @ (posedge clk) begin
		if(rst == `RstEnable) begin
				mem_wd <= `NOPRegAddr;
				mem_wreg <= `WriteDisable;
				mem_wdata <= `ZeroWord;

				mem_hi <= `ZeroWord;
				mem_lo <= `ZeroWord;
				mem_whilo <= `WriteDisable;
			
				hilo_o <= { `ZeroWord , `ZeroWord };
				cnt_o <= 2'b00;

				mem_aluop <= `EXE_NOP_OP;
				mem_addr <= `ZeroWord;
				mem_reg2 <= `ZeroWord;	

				mem_cp0_reg_we <= `WriteDisable;
				mem_cp0_reg_write_addr <= 5'b00000;
				mem_cp0_reg_data <= `ZeroWord;	

				mem_excepttype <= `ZeroWord;
				mem_is_in_delayslot <= `NotInDelaySlot;
				mem_current_inst_address <= `ZeroWord;
		end 

		else if(flush == 1'b1 ) begin
				mem_wd <= `NOPRegAddr;
				mem_wreg <= `WriteDisable;
				mem_wdata <= `ZeroWord;
				mem_hi <= `ZeroWord;
				mem_lo <= `ZeroWord;
				mem_whilo <= `WriteDisable;
				mem_aluop <= `EXE_NOP_OP;
				mem_addr <= `ZeroWord;
				mem_reg2 <= `ZeroWord;
				mem_cp0_reg_we <= `WriteDisable;
				mem_cp0_reg_write_addr <= 5'b00000;
				mem_cp0_reg_data <= `ZeroWord;
				mem_excepttype <= `ZeroWord;
				mem_is_in_delayslot <= `NotInDelaySlot;
				mem_current_inst_address <= `ZeroWord;
				hilo_o <= {`ZeroWord, `ZeroWord};
				cnt_o <= 2'b00;	    	    				
		end
			//ex is busy, so mem cant get new value now, because the are not produced yet! just let it do nothing
		else if(stall[3] == `Stop && stall[4] == `NoStop) begin
				mem_wd <= `NOPRegAddr;
				mem_wreg <= `WriteDisable;
				mem_wdata <= `ZeroWord;
				mem_hi <= `ZeroWord;
				mem_lo <= `ZeroWord;
				mem_whilo <= `WriteDisable;
				hilo_o <= hilo_i;
				cnt_o <= cnt_i;
				mem_aluop <= `EXE_NOP_OP;
				mem_addr <= `ZeroWord;
				mem_reg2 <= `ZeroWord;	

				mem_cp0_reg_we <= `WriteDisable;
				mem_cp0_reg_write_addr <= 5'b00000;
				mem_cp0_reg_data <= `ZeroWord;

				mem_excepttype <= `ZeroWord;
				mem_is_in_delayslot <= `NotInDelaySlot;
				mem_current_inst_address <= `ZeroWord;

		end

		else  if(stall[3] == `NoStop)   begin		
				mem_wd <= ex_wd;
				mem_wreg <= ex_wreg;
				mem_wdata <= ex_wdata;

				mem_hi <= ex_hi;
				mem_lo <= ex_lo;
				mem_whilo <= ex_whilo;

				hilo_o <= {`ZeroWord, `ZeroWord};
				cnt_o <= 2'b00;

				mem_aluop <= ex_aluop;
				mem_addr <= ex_mem_addr;
				mem_reg2 <= ex_reg2;	

				mem_cp0_reg_we <= ex_cp0_reg_we;
				mem_cp0_reg_write_addr <= ex_cp0_reg_write_addr;
				mem_cp0_reg_data <= ex_cp0_reg_data;
				
				mem_excepttype <= ex_excepttype;
				mem_is_in_delayslot <= ex_is_in_delayslot;
	    		mem_current_inst_address <= ex_current_inst_address;	

		end
		else begin
				hilo_o <= hilo_i;
				cnt_o <= cnt_i;
		end
	end

endmodule
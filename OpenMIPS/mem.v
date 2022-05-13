`include"def.v"
/*
		find out the exception reason, according to the information gathered in id, ex stage,
	and cp0.
		cp0's Status and Cause register holds the most recent exception's information,
	we can use it as our guideline to handle the exception.
		However, we can not directly use the value read from cp0, since there is data hazard.
	The wb's value may be more recent(produced by the last instruction)

*/
module mem(
	input wire 						rst,
	// 来自执行阶 段的信息
	input wire[`RegAddrBus]	   		wd_i,
	input wire 	 	          		wreg_i,
	input wire[`RegBus]     	  	wdata_i,
	
	input wire[`RegBus]           	hi_i,
	input wire[`RegBus]            	lo_i,
	input wire                      whilo_i,	

  	input wire[`AluOpBus]        	aluop_i,
	input wire[`RegBus]          	mem_addr_i,
	input wire[`RegBus]          	reg2_i,

	//来自memory的信息
	input wire[`RegBus]          	mem_data_i,

	//LLbit_i是LLbit寄存器的值
	input wire                  	LLbit_i,
	//但不一定是最新值，回写阶段可能要写LLbit，所以还要进一步判断
	input wire                  	wb_LLbit_we_i,
	input wire                  	wb_LLbit_value_i,

	input wire[31:0]             	excepttype_i,
	input wire                   	is_in_delayslot_i,
	input wire[`RegBus]          	current_inst_address_i,	

	//from CP0.但不一定是最新的值，要防止回写阶段指令写CP0
	input wire[`RegBus]          	cp0_status_i,
	input wire[`RegBus]          	cp0_cause_i,
	//由于异常处理被放在了mem阶段，处理完之后需要返回，所以mem需要知道返回的地址epc, 以传给ctrl
	//如果当前还处在异常级中，即异常处理还未完成，则不用返回(ctrl不给出new_pc)
	input wire[`RegBus]          	cp0_epc_i,					//从cp0读到的上一次epc，用于修改pc

	//last instruction's wb. May produce a newer cp0 here  
  	input wire                    	wb_cp0_reg_we,
	input wire[4:0]               	wb_cp0_reg_write_addr,
	input wire[`RegBus]           	wb_cp0_reg_data,

	output reg[31:0]             	excepttype_o,
	output wire[`RegBus]         	cp0_epc_o,					//要写入的epc最新值,其实就是返回值
	output wire                  	is_in_delayslot_o,			//to ctrl
	
	output wire[`RegBus]         	current_inst_address_o,

	output reg                   	LLbit_we_o,
	output reg                   	LLbit_value_o,

	//协处理器CP0的写信号
	input wire                   	cp0_reg_we_i,
	input wire[4:0]              	cp0_reg_write_addr_i,
	input wire[`RegBus]          	cp0_reg_data_i,

	output reg                   	cp0_reg_we_o,
	output reg[4:0]              	cp0_reg_write_addr_o,
	output reg[`RegBus]          	cp0_reg_data_o,

	//送到memory的信息
	output reg[`RegBus]         	mem_addr_o,
	output wire						mem_we_o,
	output reg[3:0]  	            mem_sel_o,	
	/*	
		tell which bytes are valid(the one we need).
		because the data bus is 32 bits wide, 
		and it always reads 4 aligned bytes at a time.(for portable reason,and simpilify designing)
		but some instructions only use part of them
		so we need to select the bytes we really need so that we can manipulate them later
	
		for example, we may want to read address 1, but 
		in fact the data bus reads address 0 to 3 at the same time,
		since only the byte 2(address 0 is the first) is what we needed, we set sel = 0100 to 
	*/
	output reg[`RegBus] 	        mem_data_o,
	output reg          	        mem_ce_o,
	//访存阶段的结果
	output reg[`RegAddrBus]  		wd_o,
	output reg 	           			wreg_o,
	output reg[`RegBus]          	wdata_o,

	output reg[`RegBus]           	hi_o,
	output reg[`RegBus]           	lo_o,
	output reg                      whilo_o
);
	wire[`RegBus] zero32;
	reg  mem_we;
	assign mem_we_o = mem_we;
	assign zero32 = `ZeroWord;

	reg[`RegBus]          cp0_status;
	reg[`RegBus]          cp0_cause;
	reg[`RegBus]          cp0_epc;	

	assign is_in_delayslot_o = is_in_delayslot_i;
	assign current_inst_address_o = current_inst_address_i;
	assign cp0_epc_o = cp0_epc;

	reg LLbit;	

	//获取最新的LLbit的值
	always @ (*) begin
		if(rst == `RstEnable) begin
			LLbit <= 1'b0;
		end
					else begin
			if(wb_LLbit_we_i == 1'b1) begin
				LLbit <= wb_LLbit_value_i;		//this one is newer, choose it if possible
			end 
			else begin
				LLbit <= LLbit_i;
			end
		end
	end

	always @ (*) begin
		if(rst == `RstEnable) begin
			wd_o <= `NOPRegAddr;
			wreg_o <= `WriteDisable;
			wdata_o <= `ZeroWord;

		  	hi_o <= `ZeroWord;
			lo_o <= `ZeroWord;
		  	whilo_o <= `WriteDisable;	
			mem_addr_o <= `ZeroWord;
		  	mem_we <= `WriteDisable;
		  	mem_sel_o <= 4'b0000;
		  	mem_data_o <= `ZeroWord;
		  	mem_ce_o <= `ChipDisable;	

		  	LLbit_we_o <= 1'b0;
		  	LLbit_value_o <= 1'b0;

			cp0_reg_we_o <= `WriteDisable;
		  	cp0_reg_write_addr_o <= 5'b00000;
		  	cp0_reg_data_o <= `ZeroWord;
		end 
		else begin
			//set default(initial) values
			wd_o <= wd_i;
			wreg_o <= wreg_i;
			wdata_o <= wdata_i;
			hi_o <= hi_i;
			lo_o <= lo_i;
			whilo_o <= whilo_i;	
			mem_we <= `WriteDisable;
			mem_addr_o <= `ZeroWord;
			mem_sel_o <= 4'b1111;
			mem_ce_o <= `ChipDisable;

			LLbit_we_o <= 1'b0;
		 	LLbit_value_o <= 1'b0;

			//将对cp0的写信息传递到下一阶段
			cp0_reg_we_o <= cp0_reg_we_i;
		  	cp0_reg_write_addr_o <= cp0_reg_write_addr_i;
		  	cp0_reg_data_o <= cp0_reg_data_i;	

			//communicate with RAM
			case (aluop_i)
				`EXE_LB_OP:		begin
					mem_addr_o <= mem_addr_i;
					mem_we <= `WriteDisable;
					mem_ce_o <= `ChipEnable;
					case (mem_addr_i[1:0])
						2'b00:	begin
							wdata_o <= {{24{mem_data_i[31]}},mem_data_i[31:24]};		//signed-extended 
							mem_sel_o <= 4'b1000;			//select the 1st byte
						end
						2'b01:	begin
							wdata_o <= {{24{mem_data_i[23]}},mem_data_i[23:16]};
							mem_sel_o <= 4'b0100;
						end
						2'b10:	begin
							wdata_o <= {{24{mem_data_i[15]}},mem_data_i[15:8]};
							mem_sel_o <= 4'b0010;
						end
						2'b11:	begin
							wdata_o <= {{24{mem_data_i[7]}},mem_data_i[7:0]};
							mem_sel_o <= 4'b0001;
						end
						default:	begin
							wdata_o <= `ZeroWord;
						end
					endcase
				end
				`EXE_LBU_OP:		begin
					mem_addr_o <= mem_addr_i;
					mem_we <= `WriteDisable;
					mem_ce_o <= `ChipEnable;
					case (mem_addr_i[1:0])
						2'b00:	begin
							wdata_o <= {{24{1'b0}},mem_data_i[31:24]};
							mem_sel_o <= 4'b1000;
						end
						2'b01:	begin
							wdata_o <= {{24{1'b0}},mem_data_i[23:16]};
							mem_sel_o <= 4'b0100;
						end
						2'b10:	begin
							wdata_o <= {{24{1'b0}},mem_data_i[15:8]};
							mem_sel_o <= 4'b0010;
						end
						2'b11:	begin
							wdata_o <= {{24{1'b0}},mem_data_i[7:0]};
							mem_sel_o <= 4'b0001;
						end
						default:	begin
							wdata_o <= `ZeroWord;
						end
					endcase				
				end
				`EXE_LH_OP:		begin
					mem_addr_o <= mem_addr_i;
					mem_we <= `WriteDisable;
					mem_ce_o <= `ChipEnable;
					case (mem_addr_i[1:0])
						2'b00:	begin
							wdata_o <= {{16{mem_data_i[31]}},mem_data_i[31:16]};
							mem_sel_o <= 4'b1100;
						end
						2'b10:	begin
							wdata_o <= {{16{mem_data_i[15]}},mem_data_i[15:0]};
							mem_sel_o <= 4'b0011;
						end
						default:	begin
							wdata_o <= `ZeroWord;
						end
					endcase					
				end
				`EXE_LHU_OP:		begin
					mem_addr_o <= mem_addr_i;
					mem_we <= `WriteDisable;
					mem_ce_o <= `ChipEnable;
					case (mem_addr_i[1:0])
						2'b00:	begin
							wdata_o <= {{16{1'b0}},mem_data_i[31:16]};
							mem_sel_o <= 4'b1100;
						end
						2'b10:	begin
							wdata_o <= {{16{1'b0}},mem_data_i[15:0]};
							mem_sel_o <= 4'b0011;
						end
						default:	begin
							wdata_o <= `ZeroWord;
						end
					endcase				
				end
				`EXE_LW_OP:		begin
					mem_addr_o <= mem_addr_i;
					mem_we <= `WriteDisable;
					wdata_o <= mem_data_i;
					mem_sel_o <= 4'b1111;
					mem_ce_o <= `ChipEnable;		
				end
				/*
					lwl:
					1.read an aligned word from memory 
					2.combine reg2's value and the data we just read to produce the final result
					how to combine is based on the last 2 bits of mem_address.
					In general, we load to the left side of reg2, so its right side may remain unchanged when the address is not so nice
				*/
				`EXE_LWL_OP:		begin
					mem_addr_o <= {mem_addr_i[31:2], 2'b00};
					mem_we <= `WriteDisable;
					mem_sel_o <= 4'b1111;
					mem_ce_o <= `ChipEnable;
					case (mem_addr_i[1:0])
						2'b00:	begin
							wdata_o <= mem_data_i[31:0];
						end
						//combine the ram date's value with reg's original value
						2'b01:	begin
							wdata_o <= {mem_data_i[23:0],reg2_i[7:0]};
						end
						2'b10:	begin
							wdata_o <= {mem_data_i[15:0],reg2_i[15:0]};
						end
						2'b11:	begin
							wdata_o <= {mem_data_i[7:0],reg2_i[23:0]};	
						end
						default:	begin
							wdata_o <= `ZeroWord;
						end
					endcase				
				end
				`EXE_LWR_OP:		begin
					//load a word and store it to right part of reg2, similar to lwl
					mem_addr_o <= {mem_addr_i[31:2], 2'b00};
					mem_we <= `WriteDisable;
					mem_sel_o <= 4'b1111;
					mem_ce_o <= `ChipEnable;
					case (mem_addr_i[1:0])
						2'b00:	begin
							wdata_o <= {reg2_i[31:8],mem_data_i[31:24]};
						end
						2'b01:	begin
							wdata_o <= {reg2_i[31:16],mem_data_i[31:16]};
						end
						2'b10:	begin
							wdata_o <= {reg2_i[31:24],mem_data_i[31:8]};
						end
						2'b11:	begin
							wdata_o <= mem_data_i;	
						end
						default:	begin
							wdata_o <= `ZeroWord;
						end
					endcase					
				end
				`EXE_SB_OP:		begin
					mem_addr_o <= mem_addr_i;
					mem_we <= `WriteEnable;
					mem_data_o <= {reg2_i[7:0],reg2_i[7:0],reg2_i[7:0],reg2_i[7:0]};
					mem_ce_o <= `ChipEnable;
					case (mem_addr_i[1:0])
						2'b00:	begin
							mem_sel_o <= 4'b1000;
						end
						2'b01:	begin
							mem_sel_o <= 4'b0100;
						end
						2'b10:	begin
							mem_sel_o <= 4'b0010;
						end
						2'b11:	begin
							mem_sel_o <= 4'b0001;	
						end
						default:	begin
							mem_sel_o <= 4'b0000;
						end
					endcase				
				end
				`EXE_SH_OP:		begin
					mem_addr_o <= mem_addr_i;
					mem_we <= `WriteEnable;
					mem_data_o <= {reg2_i[15:0],reg2_i[15:0]};
					mem_ce_o <= `ChipEnable;
					case (mem_addr_i[1:0])
						2'b00:	begin
							mem_sel_o <= 4'b1100;
						end
						2'b10:	begin
							mem_sel_o <= 4'b0011;
						end
						default:	begin
							mem_sel_o <= 4'b0000;
						end
					endcase						
				end
				`EXE_SW_OP:		begin
					mem_addr_o <= mem_addr_i;
					mem_we <= `WriteEnable;
					mem_data_o <= reg2_i;
					mem_sel_o <= 4'b1111;	
					mem_ce_o <= `ChipEnable;		
				end
				`EXE_SWL_OP:		begin
					mem_addr_o <= {mem_addr_i[31:2], 2'b00};
					mem_we <= `WriteEnable;
					mem_ce_o <= `ChipEnable;
					case (mem_addr_i[1:0])
						2'b00:	begin						  
							mem_sel_o <= 4'b1111;
							mem_data_o <= reg2_i;
						end
						2'b01:	begin
							mem_sel_o <= 4'b0111;
							mem_data_o <= {zero32[7:0],reg2_i[31:8]};
						end
						2'b10:	begin
							mem_sel_o <= 4'b0011;
							mem_data_o <= {zero32[15:0],reg2_i[31:16]};
						end
						2'b11:	begin
							mem_sel_o <= 4'b0001;	
							mem_data_o <= {zero32[23:0],reg2_i[31:24]};
						end
						default:	begin
							mem_sel_o <= 4'b0000;
						end
					endcase							
				end
				`EXE_SWR_OP:		begin
					mem_addr_o <= {mem_addr_i[31:2], 2'b00};
					mem_we <= `WriteEnable;
					mem_ce_o <= `ChipEnable;
					case (mem_addr_i[1:0])
						2'b00:	begin						  
							mem_sel_o <= 4'b1000;
							mem_data_o <= {reg2_i[7:0],zero32[23:0]};
						end
						2'b01:	begin
							mem_sel_o <= 4'b1100;
							mem_data_o <= {reg2_i[15:0],zero32[15:0]};
						end
						2'b10:	begin
							mem_sel_o <= 4'b1110;
							mem_data_o <= {reg2_i[23:0],zero32[7:0]};
						end
						2'b11:	begin
							mem_sel_o <= 4'b1111;	
							mem_data_o <= reg2_i[31:0];
						end
						default:	begin
							mem_sel_o <= 4'b0000;
						end
					endcase											
				end 

				//		LL and SC, special load and store instructions
				/*
							MIPS don't guarantee atomic operations, instead it use these ll and sc pair instructions to offer a kind of check.
						ll set a special bit to LLbit,and sc checks the LLbit before storing.If nothing interrupts the operation sequence, 
						sc will see that LLbit is set and know the previous operation is atomic.So it can safely store the value.
						however, if something went wrong between the sequence, like interrupt, the LLbit will be wiped out, so the next sc will see and do nothing.

							That's all MIPS can do. Well, at least better than write a wrong value. But it don't actually solve the problem.
						So programmer need to design their codes carefully by using the 2 instructions to truly support atomic operation.
						
				*/

				//		ll rt, offset(base):
				/*
						1.read a **byte** from the particular address, signed-extended it, and load to rt
						2.set LLbit = 1(extra step, differrent from other loads )
				*/
				`EXE_LL_OP:		begin
					mem_addr_o <= mem_addr_i;
					mem_we <= `WriteDisable;
					wdata_o <= mem_data_i;	
					LLbit_we_o <= 1'b1;
					LLbit_value_o <= 1'b1;
					mem_sel_o <= 4'b1111;			
					mem_ce_o <= `ChipEnable;						
				end			
				//		SC: STORE CONDITION    
				//		usage:sc rt, offset(base)
				/*
							1.If LLbit = 1, safely store the rt's value to the address.
								then set rt = 1, reset LLbit = 0
							2.If LLbit = 0, can not store to the address.
								then set rt = 0
				*/
				`EXE_SC_OP:		begin
					if(LLbit == 1'b1) begin
						LLbit_we_o <= 1'b1;
						LLbit_value_o <= 1'b0;	
						mem_addr_o <= mem_addr_i;
						mem_we <= `WriteEnable;
						mem_data_o <= reg2_i;
						wdata_o <= 32'b1;		//flag of success
						mem_sel_o <= 4'b1111;		
						mem_ce_o <= `ChipEnable;				
					end 
					else begin
						wdata_o <= 32'b0;
					end
				end	
				
				default:		begin
				end
			endcase	
		end
	end
	//获得最新的cp0信息
	always @ (*) begin
		if(rst == `RstEnable) begin
			cp0_status <= `ZeroWord;
		end 
		else if((wb_cp0_reg_we == `WriteEnable) && (wb_cp0_reg_write_addr == `CP0_REG_STATUS ))begin
			cp0_status <= wb_cp0_reg_data;
		end 
		else begin
		  	cp0_status <= cp0_status_i;
		end
	end
	
	//get the newest epc, set to ctrl to produce the new_pc
	always @ (*) begin
		if(rst == `RstEnable) begin
			cp0_epc <= `ZeroWord;
		end 
		else if((wb_cp0_reg_we == `WriteEnable) && (wb_cp0_reg_write_addr == `CP0_REG_EPC ))begin
			cp0_epc <= wb_cp0_reg_data;
		end 
		else begin
		  	cp0_epc <= cp0_epc_i;
		end
	end

	//only part of the Cause register is writable
  	always @ (*) begin
		if(rst == `RstEnable) begin
			cp0_cause <= `ZeroWord;
		end 
		//the wb value is newer than directly read from cp0
		else if((wb_cp0_reg_we == `WriteEnable) && (wb_cp0_reg_write_addr == `CP0_REG_CAUSE ))begin
			cp0_cause[9:8] <= wb_cp0_reg_data[9:8];		//IP[1:0], software interrupt pending
			cp0_cause[22] <= wb_cp0_reg_data[22];		//WP, watch pending
			cp0_cause[23] <= wb_cp0_reg_data[23];		//IV, interrupt vector.
			//Unluckily, these are all not implemented yet
		end 
		else begin
		  	cp0_cause <= cp0_cause_i;
		end
	end

	//give the final exception type
	always @ (*) begin
		if(rst == `RstEnable) begin
			excepttype_o <= `ZeroWord;
		end 
		else begin
			excepttype_o <= `ZeroWord;
			/*	three cases of current inst addr=0:
				1.in rst state
				2.the pipeline is flushed(exception handling)
				3.the pipeline is stalled(busy)
			*/
			//in these cases we don't need to deal with exception
			//bug: what if the 1st instruction itself causess an exception?
			if(current_inst_address_i != `ZeroWord) begin
				//im7-im0,屏蔽相关中断
				if(((cp0_cause[15:8] & (cp0_status[15:8])) != 8'h00) && (cp0_status[1] == 1'b0) && (cp0_status[0] == 1'b1)) begin
					excepttype_o <= 32'h00000001;        //interrupt
				end
				else if(excepttype_i[8] == 1'b1) begin
					excepttype_o <= 32'h00000008;        //syscall
				end
				else if(excepttype_i[9] == 1'b1) begin
					excepttype_o <= 32'h0000000a;        //inst_invalid
				end
				else if(excepttype_i[10] ==1'b1) begin
					excepttype_o <= 32'h0000000d;        //trap
				end
				else if(excepttype_i[11] == 1'b1) begin  //ov
					excepttype_o <= 32'h0000000c;
				end
				else if(excepttype_i[12] == 1'b1) begin  //eret
					excepttype_o <= 32'h0000000e;
				end
			end
				
		end
	end			
	//精确异常，发生异常时，引起异常以及紧跟在他后面已经进入流水线的指令都要失效。
	//对于存储指令，要使其失效只要修改使能
	//|表示“自交”运算符，将32位长的excepttype逐位互相做或运算，最终得到一位结果
	//只要有异常发生，那么其值不为0，就会或出1来
	assign mem_we_o = mem_we & (~(|excepttype_o));
endmodule
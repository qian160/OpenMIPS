`include"def.v"
/*
	自陷，溢出异常
*/
module ex(
	input wire 						rst,
	input wire[`AluOpBus]     	 	aluop_i,
	input wire[`AluSelBus]      	alusel_i,
	input wire[`RegBus]          	reg1_i,
	input wire[`RegBus]          	reg2_i,
	input wire[`RegAddrBus]  		wd_i,
	input wire 						wreg_i,

	input wire[`RegBus]           	hi_i,
	input wire[`RegBus]           	lo_i,
	
	input wire[`RegBus]           	wb_hi_i,
	input wire[`RegBus]           	wb_lo_i,
	input wire                     	wb_whilo_i,

	input wire[31:0]              	excepttype_i,
	input wire[`RegBus]          	current_inst_address_i,	

	input wire[`RegBus]           	mem_hi_i,
	input wire[`RegBus]          	mem_lo_i,
	input wire                    	mem_whilo_i,
	
	//load and store
	input wire[15:0]				ex_branch_offset_i,		//may become the later opdata for load and store in mem stage
	//branch_offset_o is not needed, it will become the mem_addr_o 
	//branch
	//分支的运算都在id阶段做了，ex好像没什么好做的了，最多只要写入链接地址到$31
	input wire[`RegBus] 			link_address_i,
	input wire 						is_in_delayslot_i,	//用于异常处理

	input wire[`DoubleRegBus]  		div_result_i,
	input wire 						div_ready_i,
	output reg[`RegAddrBus] 		wd_o,
	output reg 						wreg_o,
	output reg[`RegBus] 			wdata_o,

	output reg[`RegBus]           	hi_o,
	output reg[`RegBus]           	lo_o,
	output reg                     	whilo_o,

	//madd,msun...inst,which takes 2 periods to execuate
	input wire[`DoubleRegBus]    	hilo_temp_i,
	input wire[1:0]               	cnt_i,
	output reg[`DoubleRegBus]   	hilo_temp_o,
	output reg[1:0]               	cnt_o,
	
	output reg[`RegBus]           	div_opdata1_o,
	output reg[`RegBus]           	div_opdata2_o,
	output reg                    	div_start_o,
	output reg                    	signed_div_o,

	output wire[`AluOpBus]			aluop_o,			//for ram
	output wire[`RegBus]			mem_addr_o,
	output wire[`RegBus]			reg2_o,				//opdata for load and store
	//holds the value need to be stored, or the original value of the loaded reg(for combination)
	
	//data hazard----------------------
  	input wire                    	mem_cp0_reg_we,
	input wire[4:0]               	mem_cp0_reg_write_addr,
	input wire[`RegBus]           	mem_cp0_reg_data,
	
  	input wire                    	wb_cp0_reg_we,
	input wire[4:0]               	wb_cp0_reg_write_addr,
	input wire[`RegBus]           	wb_cp0_reg_data,
	//---------------------------------

	//与CP0相连，读取其中CP0寄存器的值
	input wire[`RegBus]           	cp0_reg_data_i,
	output reg[4:0]               	cp0_reg_read_addr_o,

	//向下一流水级传递，用于写CP0中的寄存器
	output reg                    	cp0_reg_we_o,
	output reg[4:0]               	cp0_reg_write_addr_o,
	output reg[`RegBus]           	cp0_reg_data_o,
	output reg 						stallreq,

	output wire[31:0]             	excepttype_o,
	output wire                   	is_in_delayslot_o,
	output wire[`RegBus]          	current_inst_address_o
);
	
	reg[`RegBus] 					logicout;
	reg[`RegBus] 					shiftres;
	reg[`RegBus] 					moveres;
	reg[`RegBus] 					arithmeticres; 
	reg[`DoubleRegBus]				mulres; 
	reg[`RegBus] 					HI;
	reg[`RegBus] 					LO;

	wire[`RegBus] 					reg2_i_mux;		
	wire[`RegBus] 					reg1_i_not;	
	wire[`RegBus] 					result_sum;
	wire 							ov_sum;	        //overflow
	wire 							reg1_eq_reg2;
	wire 							reg1_lt_reg2;	//less than
	wire[`RegBus]			 		opdata1_mult;	//
	wire[`RegBus] 					opdata2_mult;	//
	wire[`DoubleRegBus] 			hilo_temp;		//saves the temp multiply result,need to be modified
	reg[`DoubleRegBus] 				hilo_temp1;     //saves the multiple-period multiply result.Only avaliable in the 2nd stage
	
	reg		stallreq_for_div;
	reg		stallreq_for_madd_msub;	

	reg 	trapassert;			//自陷异常
	reg 	ovassert;			//溢出异常
	//1.logical arithmetic---------------------------------------------------------------------------------
	
	assign aluop_o = aluop_i;
	assign mem_addr_o  = reg1_i + { {16{ex_branch_offset_i[15]} }, ex_branch_offset_i };
	assign reg2_o = reg2_i;
	//执行阶段输出的异常信息就是译码阶段的异常信息(syscall, eret)加上本阶段的自陷trap，溢出
	assign excepttype_o = {excepttype_i[31:12],ovassert,trapassert,excepttype_i[9:8],8'h00};
	
	assign is_in_delayslot_o = is_in_delayslot_i;

	assign current_inst_address_o = current_inst_address_i;

	always @ (*) begin
		if(rst == ` RstEnable) begin
			logicout <= ` ZeroWord;
		end 
		else begin
			case (aluop_i)
				`EXE_OR_OP:  begin
					logicout <= reg1_i | reg2_i;
				 		end
				`EXE_AND_OP:  begin
					logicout <= reg1_i & reg2_i;
				end
				`EXE_NOR_OP:begin
					logicout <= ~(reg1_i |reg2_i);
				end
				`EXE_XOR_OP:  begin
					logicout <= reg1_i ^ reg2_i;
				end
				default:  begin
					logicout <= ` ZeroWord;
				end
			endcase
		end //if
	end //always

	//2.shift----------------------------------------------------------------------------------------------------------

	//sllv rd, rt, rs   means   rd < - rt << rs[ 4:0] (logic)
	always @ (*) begin
		if(rst == `RstEnable) begin
			shiftres <= `ZeroWord;
		end 
		else begin
			case (aluop_i)
				`EXE_SLL_OP:   begin
					shiftres <= reg2_i << reg1_i[4:0] ;
				end
				`EXE_SRL_OP:   begin
					shiftres <= reg2_i >> reg1_i[4:0];
				end
				`EXE_SRA_OP:   begin
					shiftres <= ({32{reg2_i[31]}} << (6'd32-{1'b0, reg1_i[4:0]})) 
												| reg2_i >> reg1_i[4:0];
				end
				default:		   begin
					shiftres <= `ZeroWord;
				end
			endcase
		end    //if
	end      //always

	//3.move-----------------------------------------------------------------------------------------------------------

	//获取最新的hilo
	// if   id   ex   mem   wb	
	// 		if   id   ex   mem   wb
	// 			 if   id   ex   mem   wb
	
	always @ (*) begin
		if(rst == `RstEnable) begin
			{HI,LO} <= {`ZeroWord,`ZeroWord};
		end 
		else if(mem_whilo_i == `WriteEnable) begin		//last inst edited hilo
			{HI,LO} <= {mem_hi_i,mem_lo_i};
		end 
		else if(wb_whilo_i == `WriteEnable) begin		//last last inst,between 2  pipeline stages 
			{HI,LO} <= {wb_hi_i,wb_lo_i};
		end 
		else begin										//no data hazard
			{HI,LO} <= {hi_i,lo_i};			
		end
	end	

	//MFHI MFLO MOVN MOVZ, choose the move result
	always @ (*) begin
		if(rst == `RstEnable) begin
		  		moveres <= `ZeroWord;
	 	 end 
		 else begin
			   moveres <= `ZeroWord;
			   case (aluop_i)
	   			`EXE_MFHI_OP:  begin
	   				moveres <= HI;
	   			end
	   			`EXE_MFLO_OP:  begin
	   				moveres <= LO;
	   			end
	   			`EXE_MOVZ_OP:  begin
	   				moveres <= reg1_i;
	   			end
	   			`EXE_MOVN_OP:  begin
	   				moveres <= reg1_i;
				end
				`EXE_MFC0_OP:	begin
					//generally ex gives a signal 'raddr' to cp0, and cp0 returns the data, but this value may be too old
					cp0_reg_read_addr_o <= ex_branch_offset_i; 
	   				moveres <= cp0_reg_data_i;
					//DATA HAZARD
	   				if( mem_cp0_reg_we == `WriteEnable && mem_cp0_reg_write_addr == ex_branch_offset_i ) begin
	   					moveres <= mem_cp0_reg_data;
	   				end 
					else if( wb_cp0_reg_we == `WriteEnable && wb_cp0_reg_write_addr == ex_branch_offset_i ) begin
	   					moveres <= wb_cp0_reg_data;
	   				end
	   			end	

				default: begin

				end
	   		endcase
	  	end
	end	 


	//MTC0执行结果
	always @ (*) begin
		if(rst == `RstEnable) begin
			cp0_reg_write_addr_o <= 5'b00000;
			cp0_reg_we_o <= `WriteDisable;
			cp0_reg_data_o <= `ZeroWord;
		end 
		else if(aluop_i == `EXE_MTC0_OP) begin
			cp0_reg_write_addr_o <= ex_branch_offset_i;
			cp0_reg_we_o <= `WriteEnable;
			cp0_reg_data_o <= reg1_i;
	  	end 
		else begin
			cp0_reg_write_addr_o <= 5'b00000;
			cp0_reg_we_o <= `WriteDisable;
			cp0_reg_data_o <= `ZeroWord;
		end				
	end		

	//easy arithmetic. mainly add , sub----------------------------------------------------------------------------------------------------------

	//sub -->  plus negative(2's complement)

	assign reg2_i_mux = ((aluop_i == `EXE_SUB_OP) || (aluop_i == `EXE_SUBU_OP) ||
					 	(aluop_i == `EXE_SLT_OP)|| (aluop_i == `EXE_TLT_OP) ||
	                    (aluop_i == `EXE_TLTI_OP) || (aluop_i == `EXE_TGE_OP) ||
	                    (aluop_i == `EXE_TGEI_OP)) 
					? (~reg2_i)+1 : reg2_i;
	assign result_sum = reg1_i + reg2_i_mux;

	assign ov_sum = ((!reg1_i[31] && !reg2_i_mux[31]) && result_sum[31]) || ((reg1_i[31] && reg2_i_mux[31]) && (!result_sum[31]));

	/*
		overflow :
		1.pos + pos = neg
		2.neg + neg = pos
	*/

	/*

		less than: how?
		signed compare case: we do a - |b|, and check the sign bit of the result
			1.neg vs pos
			2.pos - pos = neg
			3.neg - |neg| = neg
		unsigned case: just directly compare them

		2 && 3 can be merged to result= neg, and opdatas have the same sign

	*/
	assign reg1_lt_reg2 = 	((aluop_i == `EXE_SLT_OP) || (aluop_i == `EXE_TLT_OP) ||
	                    	(aluop_i == `EXE_TLTI_OP) || (aluop_i == `EXE_TGE_OP) ||
	                    	(aluop_i == `EXE_TGEI_OP)) ? 
					((reg1_i[31] && !reg2_i[31]) || ( (reg1_i[31] == reg2_i[31] ) && result_sum[31]))
			                   :(reg1_i < reg2_i);
	/*
		signed comparation(less than):
			1.negative vs postive
			2.both negative, but result(op1 + \op2\) == negative
		unsigned comparition:
			just compare them
	*/
	assign reg1_i_not = ~reg1_i;		//why?what's the purpose to set this variable?just for clo?

	//give value to the trapassert according to the calculation
	always @ (*) begin
		if(rst == `RstEnable) begin
			trapassert <= `TrapNotAssert;
		end 
		else begin
			trapassert <= `TrapNotAssert;
			case (aluop_i)
				`EXE_TEQ_OP, `EXE_TEQI_OP:   begin
					if( reg1_i == reg2_i ) begin
						trapassert <= `TrapAssert;
					end
				end
				`EXE_TGE_OP, `EXE_TGEI_OP, `EXE_TGEIU_OP, `EXE_TGEU_OP:   begin
					if( ~reg1_lt_reg2 ) begin
						trapassert <= `TrapAssert;
					end
				end
				`EXE_TLT_OP, `EXE_TLTI_OP, `EXE_TLTIU_OP, `EXE_TLTU_OP:   begin
					if( reg1_lt_reg2 ) begin
						trapassert <= `TrapAssert;
					end
				end
				`EXE_TNE_OP, `EXE_TNEI_OP:   begin
					if( reg1_i != reg2_i ) begin
						trapassert <= `TrapAssert;
					end
				end
				default:		   begin
					trapassert <= `TrapNotAssert;
				end
			endcase
		end
	end

	always @ (*) begin
		if(rst == `RstEnable) begin
			arithmeticres <= `ZeroWord;
		end 
		else begin
			case (aluop_i)
				`EXE_SLT_OP, `EXE_SLTU_OP:	begin
					arithmeticres <= reg1_lt_reg2 ;
				end
				`EXE_ADD_OP, `EXE_ADDU_OP, `EXE_ADDI_OP, `EXE_ADDIU_OP:  begin
					arithmeticres <= result_sum; 
				end
				`EXE_SUB_OP, `EXE_SUBU_OP:	  begin
					arithmeticres <= result_sum; 
				end		
				`EXE_CLZ_OP:  begin
					arithmeticres <= reg1_i[31] ? 0 : reg1_i[30] ? 1 : reg1_i[29] ? 2 :
												reg1_i[28] ? 3 : reg1_i[27] ? 4 : reg1_i[26] ? 5 :
												reg1_i[25] ? 6 : reg1_i[24] ? 7 : reg1_i[23] ? 8 : 
												reg1_i[22] ? 9 : reg1_i[21] ? 10 : reg1_i[20] ? 11 :
												reg1_i[19] ? 12 : reg1_i[18] ? 13 : reg1_i[17] ? 14 : 
												reg1_i[16] ? 15 : reg1_i[15] ? 16 : reg1_i[14] ? 17 : 
												reg1_i[13] ? 18 : reg1_i[12] ? 19 : reg1_i[11] ? 20 :
												reg1_i[10] ? 21 : reg1_i[9] ? 22 : reg1_i[8] ? 23 : 
												reg1_i[7] ? 24 : reg1_i[6] ? 25 : reg1_i[5] ? 26 : 
												reg1_i[4] ? 27 : reg1_i[3] ? 28 : reg1_i[2] ? 29 : 
												reg1_i[1] ? 30 : reg1_i[0] ? 31 : 32 ;
				end
				`EXE_CLO_OP:  begin
					arithmeticres <= (reg1_i_not[31] ? 0 : reg1_i_not[30] ? 1 : reg1_i_not[29] ? 2 :
												reg1_i_not[28] ? 3 : reg1_i_not[27] ? 4 : reg1_i_not[26] ? 5 :
												reg1_i_not[25] ? 6 : reg1_i_not[24] ? 7 : reg1_i_not[23] ? 8 : 
												reg1_i_not[22] ? 9 : reg1_i_not[21] ? 10 : reg1_i_not[20] ? 11 :
												reg1_i_not[19] ? 12 : reg1_i_not[18] ? 13 : reg1_i_not[17] ? 14 : 
												reg1_i_not[16] ? 15 : reg1_i_not[15] ? 16 : reg1_i_not[14] ? 17 : 
												reg1_i_not[13] ? 18 : reg1_i_not[12] ? 19 : reg1_i_not[11] ? 20 :
												reg1_i_not[10] ? 21 : reg1_i_not[9] ? 22 : reg1_i_not[8] ? 23 : 
												reg1_i_not[7] ? 24 : reg1_i_not[6] ? 25 : reg1_i_not[5] ? 26 : 
												reg1_i_not[4] ? 27 : reg1_i_not[3] ? 28 : reg1_i_not[2] ? 29 : 
												reg1_i_not[1] ? 30 : reg1_i_not[0] ? 31 : 32) ;
				end
				default:  begin
					arithmeticres <= `ZeroWord;
				end
			endcase
		end
	end

	//乘法先转化成绝对值相乘，再考虑要不要修正（变号）

	assign opdata1_mult = (((aluop_i == `EXE_MUL_OP) || 
 				(aluop_i == `EXE_MULT_OP) ||
				(aluop_i == `EXE_MADD_OP) ||
				(aluop_i == `EXE_MSUB_OP))&& 
				(reg1_i[31] == 1'b1)) ? 
			(~reg1_i + 1) : reg1_i;

  	assign opdata2_mult = (((aluop_i == `EXE_MUL_OP) || 
  				(aluop_i == `EXE_MULT_OP) ||
				(aluop_i == `EXE_MADD_OP) ||
				(aluop_i == `EXE_MSUB_OP)) && 
				(reg2_i[31] == 1'b1)) ? 
			(~reg2_i + 1) : reg2_i;	

  	assign hilo_temp = opdata1_mult * opdata2_mult;																				


	//modify the mulres(may change the sign of hilo_temp)
	always @ (*) begin
		if(rst == `RstEnable)  begin
			mulres <= {`ZeroWord,`ZeroWord};
		end 
		//signed operation
		else if ((aluop_i == `EXE_MULT_OP) || (aluop_i == `EXE_MUL_OP) ||
						 (aluop_i == `EXE_MADD_OP) || (aluop_i == `EXE_MSUB_OP))  begin
			if(reg1_i[31] ^ reg2_i[31] == 1'b1)  begin
				mulres <= ~hilo_temp + 1;
			end 
			else begin
				mulres <= hilo_temp;
			end
		end 
		else begin
			mulres <= hilo_temp;
		end
	end

	// MADD MADDU MSUB  MSUBU
	always @ (*) begin
		if(rst == `RstEnable) begin
			hilo_temp_o <= {`ZeroWord,`ZeroWord};
			cnt_o <= 2'b00;
			stallreq_for_madd_msub <= `NoStop;
		end 
		else begin
			case (aluop_i)
				`EXE_MADD_OP, `EXE_MADDU_OP:  begin
					if(cnt_i == 2'b00) begin
						hilo_temp_o <= mulres;
						cnt_o <= 2'b01;
						stallreq_for_madd_msub <= `Stop;	//1st stage, need to stall
						hilo_temp1 <= {`ZeroWord,`ZeroWord};
					end else if(cnt_i == 2'b01) begin
						hilo_temp_o <= {`ZeroWord,`ZeroWord};						
						cnt_o <= 2'b10;
						hilo_temp1 <= hilo_temp_i + {HI,LO};
						stallreq_for_madd_msub <= `NoStop;
					end
				end
				`EXE_MSUB_OP, `EXE_MSUBU_OP:  begin
					if(cnt_i == 2'b00) begin
						hilo_temp_o <=  ~mulres + 1 ;
						cnt_o <= 2'b01;
						stallreq_for_madd_msub <= `Stop;
					end 
					else if(cnt_i == 2'b01)  begin
						hilo_temp_o <= {`ZeroWord,`ZeroWord};						
						cnt_o <= 2'b10;			//complete,use 2 bits 10 instead of 0 and 1 is to avoid repeated calculate
						hilo_temp1 <= hilo_temp_i + {HI,LO};
						stallreq_for_madd_msub <= `NoStop;
					end				
				end
				default:  begin
					hilo_temp_o <= {`ZeroWord,`ZeroWord};
					cnt_o <= 2'b00;
					stallreq_for_madd_msub <= `NoStop;				
				end
			endcase
		end
	end	

	always @(*)  begin
		stallreq = stallreq_for_madd_msub || stallreq_for_div;
	end 

  	//DIV、DIVU指令	
	always @ (*) begin
		if(rst == `RstEnable) begin
			stallreq_for_div <= `NoStop;
	    	div_opdata1_o <= `ZeroWord;
			div_opdata2_o <= `ZeroWord;
			div_start_o <= `DivStop;
			signed_div_o <= 1'b0;
		end 
		else begin
			stallreq_for_div <= `NoStop;
		    div_opdata1_o <= `ZeroWord;
			div_opdata2_o <= `ZeroWord;
			div_start_o <= `DivStop;
			signed_div_o <= 1'b0;	
			
			case (aluop_i) 
				`EXE_DIV_OP:   begin
					if(div_ready_i == `DivResultNotReady) begin
	    				div_opdata1_o <= reg1_i;
						div_opdata2_o <= reg2_i;
						div_start_o <= `DivStart;
						signed_div_o <= 1'b1;
						stallreq_for_div <= `Stop;
					end 
					else if(div_ready_i == `DivResultReady) begin
	    				div_opdata1_o <= reg1_i;
						div_opdata2_o <= reg2_i;
						div_start_o <= `DivStop;
						signed_div_o <= 1'b1;
						stallreq_for_div <= `NoStop;
					end 
					else begin						
	    				div_opdata1_o <= `ZeroWord;
						div_opdata2_o <= `ZeroWord;
						div_start_o <= `DivStop;
						signed_div_o <= 1'b0;
						stallreq_for_div <= `NoStop;
					end					
				end

				`EXE_DIVU_OP:   begin
					if(div_ready_i == `DivResultNotReady) begin
	    				div_opdata1_o <= reg1_i;
						div_opdata2_o <= reg2_i;
						div_start_o <= `DivStart;
						signed_div_o <= 1'b0;
						stallreq_for_div <= `Stop;
					end 
					else if(div_ready_i == `DivResultReady) begin
	    			div_opdata1_o <= reg1_i;
						div_opdata2_o <= reg2_i;
						div_start_o <= `DivStop;
						signed_div_o <= 1'b0;
						stallreq_for_div <= `NoStop;
					end 
					else begin						
	    			div_opdata1_o <= `ZeroWord;
						div_opdata2_o <= `ZeroWord;
						div_start_o <= `DivStop;
						signed_div_o <= 1'b0;
						stallreq_for_div <= `NoStop;
					end					
				end

				default: begin
				end
			endcase
		end   //not rst
	end	


	//communicate with regfile
	//choose one result according to the alusel,or do nothing  

	always @ (*) begin			//combination logic
		wd_o <= wd_i; 	 
		if(((aluop_i == `EXE_ADD_OP) || (aluop_i == `EXE_ADDI_OP) || 
	     	(aluop_i == `EXE_SUB_OP)) && (ov_sum == 1'b1)) begin
	 			wreg_o <=  `WriteDisable;
				ovassert <= 1'b1;
		end 
		else begin
	  		wreg_o <= wreg_i;
			ovassert <= 1'b0;
	 	end
		
 		case ( alusel_i )
			`EXE_RES_LOGIC:  begin
				wdata_o <= logicout; 
			end
			`EXE_RES_SHIFT:  begin
	 			wdata_o <= shiftres;
	 		end	 	
			`EXE_RES_MOVE:  begin
	 			wdata_o <= moveres;
	 		end	 
			`EXE_RES_ARITHMETIC:  begin
	 			wdata_o <= arithmeticres;
	 		end
			`EXE_RES_MUL:  begin
	 			wdata_o <= mulres[31:0];
	 		end	 	
			`EXE_RES_JUMP_BRANCH: begin
				wdata_o <= link_address_i;
			end
			default:  begin
				wdata_o <= ` ZeroWord;
			end		
		endcase
	end

	//communicate with the hilo module
	//instructions like MULT, MULTU, MTHI/LO...... will change the hilo reg
	always @ (*) begin
		if(rst == `RstEnable) begin
			whilo_o <= `WriteDisable;
			hi_o <= `ZeroWord;
			lo_o <= `ZeroWord;		
		end 
		else if((aluop_i == `EXE_MULT_OP) || (aluop_i == `EXE_MULTU_OP)) begin
			whilo_o <= `WriteEnable;
			hi_o <= mulres[63:32];
			lo_o <= mulres[31:0];	
		end
		else if(aluop_i == `EXE_MTHI_OP) begin
			whilo_o <= `WriteEnable;
			hi_o <= reg1_i;
			lo_o <= LO;
		end 
		else if(aluop_i == `EXE_MTLO_OP) begin
			whilo_o <= `WriteEnable;
			hi_o <= HI;
			lo_o <= reg1_i;
		end 
		else if((aluop_i == `EXE_MADD_OP) || (aluop_i == `EXE_MADDU_OP)) begin
			whilo_o <= `WriteEnable;
			hi_o <= hilo_temp1[63:32];
			lo_o <= hilo_temp1[31:0];
		end 
		else if((aluop_i == `EXE_MSUB_OP) || (aluop_i == `EXE_MSUBU_OP)) begin
			whilo_o <= `WriteEnable;
			hi_o <= hilo_temp1[63:32];
			lo_o <= hilo_temp1[31:0];			
		end
		else if((aluop_i == `EXE_DIV_OP) || (aluop_i == `EXE_DIVU_OP)) begin
			whilo_o <= `WriteEnable;
			hi_o <= div_result_i[63:32];
			lo_o <= div_result_i[31:0];							
		end 
		else begin
			whilo_o <= `WriteDisable;
			hi_o <= `ZeroWord;
			lo_o <= `ZeroWord;
		end	
		
	end			
endmodule
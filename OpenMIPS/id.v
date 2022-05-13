`include"def.v"
/*
	get all the information needed to ex.
	id don't do arithmatic operations itself(except for branch target, to reduce the bubble),
	it just passes all the source opdata to ex and let it do the arithmatic.
	该阶段会检测出以下异常�?
	syscall，eret，无效指�?(默认无效，只要匹配到一个译码就变成有效)
*/
module id(
	input wire 						rst,
	input wire[`InstAddrBus] 		pc_i,			//31:0
	input wire[`InstBus] 			inst_i,

	 // ��ȡ��Regfile��ֵ
	input wire[`RegBus] 			reg1_data_i,
	input wire[`RegBus] 			reg2_data_i,		//31:0

	input wire						is_in_delayslot_i,

	input wire[`AluOpBus]			ex_aluop_i,			//load dependency

	output reg 						next_inst_in_delayslot_o,
	output reg 						branch_flag_o,
	output reg[`RegBus] 			branch_target_address_o,
	output reg[`RegBus] 			link_addr_o,
	output reg 						is_in_delayslot_o,
	// �����Regfile����Ϣ
	output reg 						reg1_read_o,
	output reg 						reg2_read_o,
	output reg[`RegAddrBus] 		reg1_addr_o,		//4:0,tell the regfile which reg we want to read
	output reg[`RegAddrBus] 		reg2_addr_o,

	// �͵�ִ�н� �ε���Ϣ
	output reg[`AluOpBus] 			aluop_o,			//7:0,����������
	output reg[`AluSelBus] 			alusel_o,			//2:0,used to select an operation type
	output reg[`RegBus] 			reg1_o,			//31:0
	output reg[`RegBus] 			reg2_o,			//normally 1 -> reg, 2 -> imm/reg
	output reg[`RegAddrBus] 		wd_o,			//4:0
	output reg 						wreg_o,

	//data hazard

	//����ִ�н� �ε�ָ���������?
	input wire 						ex_wreg_i,
	input wire[`RegBus] 			ex_wdata_i,
	input wire[`RegAddrBus] 		ex_wd_i,
	 //���ڷô��? �ε�ָ���������?
	input wire 						mem_wreg_i,
	input wire[`RegBus] 			mem_wdata_i,
	input wire[`RegAddrBus] 		mem_wd_i,

	output wire[`RegBus]			excepttype_o,				//gather the exception information
	output wire[`RegBus]			current_inst_address_o,		//��������epc(��Ҫ�Ļ�)

	//output wire[`RegBus] 			inst_o,			//Ϊ��ʵ�ַô棬��ָ��ݵ�ex�׶Σ����������ص�ַ
	output wire [15:0] 				id_branch_offset_o,
	output wire		                stallreq		//request to a stall

);

	reg excepttype_is_syscall;

	reg excepttype_is_eret;

	reg instvalid;
  	assign excepttype_o = {19'b0,excepttype_is_eret,2'b0,
  										instvalid, excepttype_is_syscall,8'b0};
  	//assign excepttye_is_trapinst = 1'b0;
  
	assign current_inst_address_o = pc_i;

	//branch prepration
	wire[`RegBus] pc_plus_8;				//link address
	wire[`RegBus] pc_plus_4;				//jump target's highest 4 bits
	wire[`RegBus] imm_sll2_signedext;		//true branch offset
	assign pc_plus_8 = pc_i + 8; 
	assign pc_plus_4 = pc_i + 4; 

	//branch target	
	assign imm_sll2_signedext = {{14{inst_i[15]}}, inst_i[15:0],2'b00 };
	
	assign id_branch_offset_o = inst_i[15:0]; 
	// ȡ��ָ���ָ���룬������?
	wire[5:0] op = inst_i[31:26];		//ָ����
	wire[4:0] op2 = inst_i[10:6];
	wire[5:0] op3 = inst_i[5:0];		//������
	wire[4:0] op4 = inst_i[20:16];
	reg[`RegBus]	 imm;

	//load dependency
	reg 	stallreq_for_reg1_loadrelate;
  	reg 	stallreq_for_reg2_loadrelate;
  	wire 	pre_inst_is_load;
	
	assign 	pre_inst_is_load = ((ex_aluop_i == `EXE_LB_OP) || 
								(ex_aluop_i == `EXE_LBU_OP)||
								(ex_aluop_i == `EXE_LH_OP) ||
								(ex_aluop_i == `EXE_LHU_OP)||
								(ex_aluop_i == `EXE_LW_OP) ||
								(ex_aluop_i == `EXE_LWR_OP)||
								(ex_aluop_i == `EXE_LWL_OP)||
								(ex_aluop_i == `EXE_LL_OP) ||
								(ex_aluop_i == `EXE_SC_OP)) ?
							1'b1 : 1'b0;

	//the only way to stall the id is load
	assign stallreq = stallreq_for_reg1_loadrelate | stallreq_for_reg2_loadrelate;
	//����
	always @ (*) begin
		if (rst == `RstEnable) begin	//reset
			aluop_o <= `EXE_NOP_OP;
			alusel_o <= `EXE_RES_NOP;
			wd_o <= `NOPRegAddr;
			wreg_o <= `WriteDisable;
			instvalid <= `InstValid;
			reg1_read_o <= 1'b0;
			reg2_read_o <= 1'b0;
			reg1_addr_o <= `NOPRegAddr;
			reg2_addr_o <= `NOPRegAddr;	//writing to reg 0 is not allowed and thus we will do nothing
			imm <= 32'h0;
			link_addr_o <= `ZeroWord;
			branch_target_address_o <= `ZeroWord;
			branch_flag_o <= `NotBranch;
			next_inst_in_delayslot_o <= `NotInDelaySlot;
			excepttype_is_syscall <= `False_v;
			excepttype_is_eret <= `False_v;
		end 
		else begin		
			//default case
			aluop_o <= `EXE_NOP_OP;
			alusel_o <= `EXE_RES_NOP;
			wd_o <= inst_i[15:11];			//default write destination
			wreg_o <= `WriteDisable;
			instvalid <= `InstInvalid;
			reg1_read_o <= 1'b0;
			reg2_read_o <= 1'b0;
			reg1_addr_o <= inst_i[25:21]; 
			reg2_addr_o <= inst_i[20:16]; 
			imm <= `ZeroWord;
			link_addr_o <= `ZeroWord;
			branch_target_address_o <= `ZeroWord;
			branch_flag_o <= `NotBranch;
			next_inst_in_delayslot_o <= `NotInDelaySlot;
			excepttype_is_syscall <= `False_v;	
			excepttype_is_eret <= `False_v;
			case (op)
		    	`EXE_SPECIAL_INST:  begin
					case (op2)
						5'b00000:	  begin
							case (op3)
								`EXE_OR:	begin
										wreg_o <= `WriteEnable;		
									aluop_o <= `EXE_OR_OP;
									alusel_o <= `EXE_RES_LOGIC; 	
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b1;
									instvalid <= `InstValid;	
								end  
								`EXE_AND:  begin
										wreg_o <= `WriteEnable;		
									aluop_o <= `EXE_AND_OP;
									alusel_o <= `EXE_RES_LOGIC;	  
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b1;	
									instvalid <= `InstValid;	
								end  	
								`EXE_XOR:  begin
										wreg_o <= `WriteEnable;		
									aluop_o <= `EXE_XOR_OP;
									alusel_o <= `EXE_RES_LOGIC;		
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b1;	
									instvalid <= `InstValid;	
								end  				
								`EXE_NOR:  begin
										wreg_o <= `WriteEnable;		
									aluop_o <= `EXE_NOR_OP;
									alusel_o <= `EXE_RES_LOGIC;		
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b1;	
									instvalid <= `InstValid;	
								end 
								`EXE_SLLV:  begin
									wreg_o <= `WriteEnable;		
									aluop_o <= `EXE_SLL_OP;
									alusel_o <= `EXE_RES_SHIFT;		
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b1;
									instvalid <= `InstValid;	
								end
								`EXE_SRLV:   begin
									wreg_o <= `WriteEnable;		
									aluop_o <= `EXE_SRL_OP;
									alusel_o <= `EXE_RES_SHIFT;		
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b1;
									instvalid <= `InstValid;	
								end 					
								`EXE_SRAV:  begin
									wreg_o <= `WriteEnable;		
									aluop_o <= `EXE_SRA_OP;
									alusel_o <= `EXE_RES_SHIFT;		
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b1;
									instvalid <= `InstValid;			
								end	
							///*
							//in fact sync's op2 == 1 != 0, so it will not go into the loop and will go to line 123's default instead of here
								`EXE_SYNC:  begin
										wreg_o <= `WriteDisable;		
										aluop_o <= `EXE_NOP_OP;
										alusel_o <= `EXE_RES_NOP;		
										reg1_read_o <= 1'b0;	
										reg2_read_o <= 1'b1;
										instvalid <= `InstValid;	
								end	

								`EXE_MFHI:  begin
										wreg_o <= `WriteEnable;		
										aluop_o <= `EXE_MFHI_OP;
										alusel_o <= `EXE_RES_MOVE;   
										reg1_read_o <= 1'b0;	
										reg2_read_o <= 1'b0;
										instvalid <= `InstValid;	
									end
								`EXE_MFLO:  begin
										wreg_o <= `WriteEnable;		
										aluop_o <= `EXE_MFLO_OP;
										alusel_o <= `EXE_RES_MOVE;   
										reg1_read_o <= 1'b0;	
										reg2_read_o <= 1'b0;
										instvalid <= `InstValid;	
									end
								`EXE_MTHI:  begin
										wreg_o <= `WriteDisable;		
										aluop_o <= `EXE_MTHI_OP;
										reg1_read_o <= 1'b1;	
										reg2_read_o <= 1'b0; 
										instvalid <= `InstValid;	
								end
								`EXE_MTLO:  begin
										wreg_o <= `WriteDisable;		
										aluop_o <= `EXE_MTLO_OP;
										reg1_read_o <= 1'b1;	
										reg2_read_o <= 1'b0; 
										instvalid <= `InstValid;	//alu don't need to do anything in mtlo and mthi
								end
								`EXE_MOVN:  begin
										aluop_o <= `EXE_MOVN_OP;
										alusel_o <= `EXE_RES_MOVE;   
										reg1_read_o <= 1'b1;	
										reg2_read_o <= 1'b1;
										instvalid <= `InstValid;
										if(reg2_o != `ZeroWord) begin
											wreg_o <= `WriteEnable;
										end 
										else begin
											wreg_o <= `WriteDisable;
										end
								end
								`EXE_MOVZ:  begin
										aluop_o <= `EXE_MOVZ_OP;
										alusel_o <= `EXE_RES_MOVE;   
										reg1_read_o <= 1'b1;	
										reg2_read_o <= 1'b1;
										instvalid <= `InstValid;

										if(reg2_o == `ZeroWord) begin
											wreg_o <= `WriteEnable;
										end 
										else begin
											wreg_o <= `WriteDisable;
										end		  							
								end
								`EXE_SLT:   begin
										wreg_o <= `WriteEnable;		
										aluop_o <= `EXE_SLT_OP;
										alusel_o <= `EXE_RES_ARITHMETIC;		
										reg1_read_o <= 1'b1;	
										reg2_read_o <= 1'b1;
										instvalid <= `InstValid;	
								end
								`EXE_SLTU:  begin
										wreg_o <= `WriteEnable;		
										aluop_o <= `EXE_SLTU_OP;
										alusel_o <= `EXE_RES_ARITHMETIC;		
										reg1_read_o <= 1'b1;	
										reg2_read_o <= 1'b1;
										instvalid <= `InstValid;	
								end
								`EXE_ADD:  begin
										wreg_o <= `WriteEnable;		
										aluop_o <= `EXE_ADD_OP;
										alusel_o <= `EXE_RES_ARITHMETIC;		
										reg1_read_o <= 1'b1;	
										reg2_read_o <= 1'b1;
										instvalid <= `InstValid;	
								end
								`EXE_ADDU:  begin
										wreg_o <= `WriteEnable;		
										aluop_o <= `EXE_ADDU_OP;
										alusel_o <= `EXE_RES_ARITHMETIC;		
										reg1_read_o <= 1'b1;	
										reg2_read_o <= 1'b1;
										instvalid <= `InstValid;	
								end
								`EXE_SUB:  begin
										wreg_o <= `WriteEnable;		
										aluop_o <= `EXE_SUB_OP;
										alusel_o <= `EXE_RES_ARITHMETIC;		
										reg1_read_o <= 1'b1;	
										reg2_read_o <= 1'b1;
										instvalid <= `InstValid;	
								end
								`EXE_SUBU:  begin
										wreg_o <= `WriteEnable;		
										aluop_o <= `EXE_SUBU_OP;
										alusel_o <= `EXE_RES_ARITHMETIC;		
										reg1_read_o <= 1'b1;	
										reg2_read_o <= 1'b1;
										instvalid <= `InstValid;	
								end
								`EXE_MULT:  begin
										wreg_o <= `WriteDisable;		
										aluop_o <= `EXE_MULT_OP;
										reg1_read_o <= 1'b1;	
										reg2_read_o <= 1'b1; 
										instvalid <= `InstValid;	
								end
								`EXE_MULTU:  begin
										wreg_o <= `WriteDisable;		
										aluop_o <= `EXE_MULTU_OP;
										reg1_read_o <= 1'b1;	
										reg2_read_o <= 1'b1; 
										instvalid <= `InstValid;	
								end 		

								`EXE_DIV: begin //divָ��
										wreg_o <= `WriteDisable;
										aluop_o <= `EXE_DIV_OP;
										reg1_read_o <= 1'b1;
										reg2_read_o <= 1'b1;
										instvalid <= `InstValid;
								end
								`EXE_DIVU: begin //divuָ��
										wreg_o <= `WriteDisable;
										aluop_o <= `EXE_DIVU_OP;
										reg1_read_o <= 1'b1;
										reg2_read_o <= 1'b1;
										instvalid <= `InstValid;
								end						  			
								`EXE_JR: begin // j rָ��
										wreg_o <= `WriteDisable;
										aluop_o <= `EXE_JR_OP;
										alusel_o <=
										`EXE_RES_JUMP_BRANCH;
										reg1_read_o <= 1'b1;
										reg2_read_o <= 1'b0;
										link_addr_o <= `ZeroWord;
										branch_target_address_o <= reg1_o;
										branch_flag_o <= `Branch;
										next_inst_in_delayslot_o <= `InDelaySlot;
										instvalid <= `InstValid;
								end
								`EXE_JALR: begin // j alrָ��
										wreg_o <= `WriteEnable;
										aluop_o <= `EXE_JALR_OP;
										alusel_o <=
										`EXE_RES_JUMP_BRANCH;
										reg1_read_o <= 1'b1;
										reg2_read_o <= 1'b0;
										wd_o <= inst_i[15:11];
										link_addr_o <= pc_plus_8;
										branch_target_address_o <= reg1_o;
										branch_flag_o <= `Branch;
										next_inst_in_delayslot_o <= `InDelaySlot;
										instvalid <= `InstValid;
								end	

								default:	begin
								end
							endcase   //op3
						end		//op2 = 5'b00000 begin
						//
						default: begin		//op1 == 0 but op2 ! = 0 ,here we do nothing
						end
			
					endcase	   //op2

					case (op3)
						`EXE_TEQ: begin
								wreg_o <= `WriteDisable;
								aluop_o <= `EXE_TEQ_OP;
								alusel_o <= `EXE_RES_NOP;   
								reg1_read_o <= 1'b0;	
								reg2_read_o <= 1'b0;
								instvalid <= `InstValid;
						end
						`EXE_TGE: begin
								wreg_o <= `WriteDisable;		
								aluop_o <= `EXE_TGE_OP;
								alusel_o <= `EXE_RES_NOP;   
								reg1_read_o <= 1'b1;	
								reg2_read_o <= 1'b1;
								instvalid <= `InstValid;
						end		
						`EXE_TGEU: begin
								wreg_o <= `WriteDisable;		
								aluop_o <= `EXE_TGEU_OP;
								alusel_o <= `EXE_RES_NOP;   
								reg1_read_o <= 1'b1;	
								reg2_read_o <= 1'b1;
								instvalid <= `InstValid;
						end	
						`EXE_TLT: begin
								wreg_o <= `WriteDisable;		
								aluop_o <= `EXE_TLT_OP;
								alusel_o <= `EXE_RES_NOP;   
								reg1_read_o <= 1'b1;	
								reg2_read_o <= 1'b1;
								instvalid <= `InstValid;
						end
						`EXE_TLTU: begin
								wreg_o <= `WriteDisable;		
								aluop_o <= `EXE_TLTU_OP;
								alusel_o <= `EXE_RES_NOP;   
								reg1_read_o <= 1'b1;	
								reg2_read_o <= 1'b1;
								instvalid <= `InstValid;
						end	
						`EXE_TNE: begin
								wreg_o <= `WriteDisable;		
								aluop_o <= `EXE_TNE_OP;
								alusel_o <= `EXE_RES_NOP;   
								reg1_read_o <= 1'b1;	
								reg2_read_o <= 1'b1;
								instvalid <= `InstValid;
						end
						`EXE_SYSCALL: begin
								wreg_o <= `WriteDisable;		
								aluop_o <= `EXE_SYSCALL_OP;
								alusel_o <= `EXE_RES_NOP;   
								reg1_read_o <= 1'b0;	
								reg2_read_o <= 1'b0;
								instvalid <= `InstValid; 
								excepttype_is_syscall<= `True_v;
						end							 																					
						default:	begin
						end	
					endcase									

				end		//op == special 
					  
				//not special instruction, op ! = 0
				//check their op to see if we can get some useful information
				`EXE_ORI:  begin                        //ORIָ��
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_OR_OP;
						alusel_o <= `EXE_RES_LOGIC; 
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b0;	  	
						imm <= {16'h0, inst_i[15:0]};		
						wd_o <= inst_i[20:16];
						instvalid <= `InstValid;	
					end
				`EXE_ANDI:  begin
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_AND_OP;
						alusel_o <= `EXE_RES_LOGIC;	
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b0;	  	
						imm <= {16'h0, inst_i[15:0]};		
						wd_o <= inst_i[20:16];		  	
						instvalid <= `InstValid;	
					end	 	
				`EXE_XORI:  begin
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_XOR_OP;
						alusel_o <= `EXE_RES_LOGIC;	
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b0;	  	
						imm <= {16'h0, inst_i[15:0]};		
						wd_o <= inst_i[20:16];		  	
						instvalid <= `InstValid;	
					end	 		
				`EXE_LUI:	begin
				//lui rt,immediate = ori rt,$0,(immediate << 16 | 0 )
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_OR_OP;
						alusel_o <= `EXE_RES_LOGIC; 
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b0;	  	
						imm <= {inst_i[15:0], 16'h0};		
						wd_o <= inst_i[20:16];		  	
						instvalid <= `InstValid;	
					end		
				`EXE_PREF:  begin
						wreg_o <= `WriteDisable;		
						aluop_o <= `EXE_NOP_OP;
						alusel_o <= `EXE_RES_NOP; 
						reg1_read_o <= 1'b0;	
						reg2_read_o <= 1'b0;	  	  	
						instvalid <= `InstValid;	
					end	
				`EXE_SLTI:  begin
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_SLT_OP;
						alusel_o <= `EXE_RES_ARITHMETIC; 
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b0;	  	
						imm <= {{16{inst_i[15]}}, inst_i[15:0]};		
						wd_o <= inst_i[20:16];		  	
						instvalid <= `InstValid;	
					end
				`EXE_SLTIU:  begin
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_SLTU_OP;
						alusel_o <= `EXE_RES_ARITHMETIC; 
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b0;	  	
						imm <= {{16{inst_i[15]}}, inst_i[15:0]};		
						wd_o <= inst_i[20:16];		  	
						instvalid <= `InstValid;	
					end
				`EXE_ADDI:  begin
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_ADDI_OP;
						alusel_o <= `EXE_RES_ARITHMETIC; 
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b0;	  	
						imm <= {{16{inst_i[15]}}, inst_i[15:0]};		
						wd_o <= inst_i[20:16];		  	
						instvalid <= `InstValid;	
					end
				`EXE_ADDIU:  begin
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_ADDIU_OP;
						alusel_o <= `EXE_RES_ARITHMETIC; 
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b0;	  	
						imm <= {{16{inst_i[15]}}, inst_i[15:0]};		
						wd_o <= inst_i[20:16];		  	
						instvalid <= `InstValid;	
					end	
				//branch begin ------------------------------------
				//for some instructions, the only wreg_o is pc, which is not part of the regfile, so set write disable
				//these jump and branch instructions are not special,can be distinguished from [31:26]
				`EXE_J : begin // j  target 
						wreg_o <= `WriteDisable;
						aluop_o <= `EXE_J_OP;
						alusel_o <= `EXE_RES_JUMP_BRANCH;
						reg1_read_o <= 1'b0;
						reg2_read_o <= 1'b0;
						link_addr_o <= `ZeroWord;
						branch_flag_o <= `Branch;
						next_inst_in_delayslot_o <= `InDelaySlot;
						instvalid <= `InstValid;
						branch_target_address_o <=
						{pc_plus_4[31:28], inst_i[25:0], 2'b00};
				end
				`EXE_JAL: begin // j  target , jump and link
				//jalҪ����תָ�� '�����?2��ָ��' �ĵ�ַ��Ϊ���ص�ַ���浽$31
						wreg_o <= `WriteEnable;
						aluop_o <= `EXE_JAL_OP;
						alusel_o <= `EXE_RES_JUMP_BRANCH;
						reg1_read_o <= 1'b0;
						reg2_read_o <= 1'b0;
						wd_o <= 5'b11111;
						link_addr_o <= pc_plus_8 ;
						branch_flag_o <= `Branch;
						next_inst_in_delayslot_o <= `InDelaySlot;
						instvalid <= `InstValid;
						branch_target_address_o <=
						{pc_plus_4[31:28], inst_i[25:0], 2'b00};
				end
				//b == beq 0 , 0
				`EXE_BEQ : begin // beq rs, rt, offset
						wreg_o <= `WriteDisable;
						aluop_o <= `EXE_BEQ_OP;
						alusel_o <= `EXE_RES_JUMP_BRANCH;
						reg1_read_o <= 1'b1;
						reg2_read_o <= 1'b1;
						instvalid <= `InstValid;
						if(reg1_o == reg2_o) begin
							branch_target_address_o <= pc_plus_4 +
							imm_sll2_signedext;
							branch_flag_o <= `Branch;
							next_inst_in_delayslot_o <= `InDelaySlot;
						end
				end
				`EXE_BGTZ: begin // bgtz rs, offset
						wreg_o <= `WriteDisable;
						aluop_o <= `EXE_BGTZ_OP;
						alusel_o <= `EXE_RES_JUMP_BRANCH;
						reg1_read_o <= 1'b1;
						reg2_read_o <= 1'b0;
						instvalid <= `InstValid;
						if((reg1_o[31] == 1'b0) & & (reg1_o != `ZeroWord)) begin
							branch_target_address_o <= pc_plus_4 +
							imm_sll2_signedext;
							branch_flag_o <= `Branch;
							next_inst_in_delayslot_o <= `InDelaySlot;
						end
				end
				`EXE_BLEZ: begin // blez rs, offset
						wreg_o <= `WriteDisable;
						aluop_o <= `EXE_BLEZ_OP;
						alusel_o <= `EXE_RES_JUMP_BRANCH;
						reg1_read_o <= 1'b1;
						reg2_read_o <= 1'b0;
						instvalid <= `InstValid;
						if((reg1_o[31] == 1'b1) || (reg1_o == `ZeroWord)) begin
							branch_target_address_o <= pc_plus_4 +
							imm_sll2_signedext;
							branch_flag_o <= `Branch;
							next_inst_in_delayslot_o <= `InDelaySlot;
						end
				end
				`EXE_BNE: begin // bne rs, rt, offset
						wreg_o <= `WriteDisable;
						aluop_o <= `EXE_BLEZ_OP;
						alusel_o <= `EXE_RES_JUMP_BRANCH;
						reg1_read_o <= 1'b1;
						reg2_read_o <= 1'b1;
						instvalid <= `InstValid;
						if(reg1_o != reg2_o) begin
							branch_target_address_o <= pc_plus_4 +
							imm_sll2_signedext;
							branch_flag_o <= `Branch;
							next_inst_in_delayslot_o <= `InDelaySlot;
						end
				end
				//load and store
				`EXE_LB:  begin
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_LB_OP;
						alusel_o <= `EXE_RES_LOAD_STORE; 
						reg1_read_o <= 1'b1;		//base reg
						reg2_read_o <= 1'b0;	  	
						wd_o <= inst_i[20:16]; 
						instvalid <= `InstValid;	
				end
				`EXE_LBU:   begin
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_LBU_OP;
						alusel_o <= `EXE_RES_LOAD_STORE; 
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b0;	  	
						wd_o <= inst_i[20:16]; 
						instvalid <= `InstValid;	
				end
				`EXE_LH:   begin
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_LH_OP;
						alusel_o <= `EXE_RES_LOAD_STORE; 
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b0;	  	
						wd_o <= inst_i[20:16]; 
						instvalid <= `InstValid;	
				end
				`EXE_LHU:   begin
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_LHU_OP;
						alusel_o <= `EXE_RES_LOAD_STORE; 
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b0;	  	
						wd_o <= inst_i[20:16]; 
						instvalid <= `InstValid;	
				end
				`EXE_LW:   begin
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_LW_OP;
						alusel_o <= `EXE_RES_LOAD_STORE; 
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b0;	  	
						wd_o <= inst_i[20:16]; 
						instvalid <= `InstValid;	
				end
				`EXE_LL:   begin
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_LL_OP;
						alusel_o <= `EXE_RES_LOAD_STORE; 
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b0;	  	
						wd_o <= inst_i[20:16]; 
						instvalid <= `InstValid;	
				end
				`EXE_LWL:   begin
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_LWL_OP;
						alusel_o <= `EXE_RES_LOAD_STORE; 
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b1;	
						//both regs need to be read, since lwl just 
						//partly modify the target reg, it will need to know the 
						//original value of the target reg. so that no data lost will occur 	
						wd_o <= inst_i[20:16]; 
						instvalid <= `InstValid;	
				end
				`EXE_LWR:   begin
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_LWR_OP;
						alusel_o <= `EXE_RES_LOAD_STORE; 
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b1;	  	
						wd_o <= inst_i[20:16]; 
						instvalid <= `InstValid;	
				end
				`EXE_SB:   begin
						wreg_o <= `WriteDisable;		
						aluop_o <= `EXE_SB_OP;
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b1; 
						instvalid <= `InstValid;	
						alusel_o <= `EXE_RES_LOAD_STORE; 
				end
				`EXE_SH:   begin
						wreg_o <= `WriteDisable;		
						aluop_o <= `EXE_SH_OP;
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b1; 
						instvalid <= `InstValid;	
						alusel_o <= `EXE_RES_LOAD_STORE; 
				end
				`EXE_SW:   begin
						wreg_o <= `WriteDisable;		
						aluop_o <= `EXE_SW_OP;
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b1; 
						instvalid <= `InstValid;	
						alusel_o <= `EXE_RES_LOAD_STORE; 
				end
				`EXE_SWL:   begin
						wreg_o <= `WriteDisable;		
						aluop_o <= `EXE_SWL_OP;
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b1; 
						instvalid <= `InstValid;	
						alusel_o <= `EXE_RES_LOAD_STORE; 
				end
				`EXE_SWR:   begin
						wreg_o <= `WriteDisable;		
						aluop_o <= `EXE_SWR_OP;
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b1; 
						instvalid <= `InstValid;	
						alusel_o <= `EXE_RES_LOAD_STORE; 
				end
				`EXE_SC:   begin
						wreg_o <= `WriteEnable;			//different from other store instructions!!	
						aluop_o <= `EXE_SC_OP;
						alusel_o <= `EXE_RES_LOAD_STORE; 
						reg1_read_o <= 1'b1;
						reg2_read_o <= 1'b1;	  	
						wd_o <= inst_i[20:16]; 
						instvalid <= `InstValid;	
						alusel_o <= `EXE_RES_LOAD_STORE; 
				end

				`EXE_LL:   begin
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_LL_OP;
						alusel_o <= `EXE_RES_LOAD_STORE; 
						reg1_read_o <= 1'b1;	
						reg2_read_o <= 1'b0;	  	
						wd_o <= inst_i[20:16]; 
						instvalid <= `InstValid;	
				end
				//bltz,bgez,bltzal,bgezal,bal have the same op1 ( 000001 ).the difference is op4 [20:16]
				`EXE_REGIMM_INST:  begin
						case (op4)
							`EXE_BGEZ: begin // bgez rs, offset
									wreg_o <= `WriteDisable;
									aluop_o <= `EXE_BGEZ_OP;
									alusel_o <= `EXE_RES_JUMP_BRANCH;
									reg1_read_o <= 1'b1;
									reg2_read_o <= 1'b0;
									instvalid <= `InstValid;
									if(reg1_o[31] == 1'b0) begin
										branch_target_address_o <=
										pc_plus_4 +
										imm_sll2_signedext;
										branch_flag_o <= `Branch;
										next_inst_in_delayslot_o <= `InDelaySlot;
									end
							end
							`EXE_BGEZAL: begin // bgezal rs, offset  (al:and link)
									//set $31 to be the link address
									//notice that bgezal 0 ,offset == bal offset
									//when rs == 0,in fact it should be the bal instruction, but we could treat that inst as a special case of bgezal.
									wreg_o <= `WriteEnable;
									aluop_o <= `EXE_BGEZAL_OP;
									alusel_o <= `EXE_RES_JUMP_BRANCH;
									reg1_read_o <= 1'b1;
									reg2_read_o <= 1'b0;
									link_addr_o <= pc_plus_8;
									wd_o <= 5'b11111;
									instvalid <= `InstValid;
									if(reg1_o[31] == 1'b0) begin
										branch_target_address_o <= pc_plus_4 + imm_sll2_signedext;
										branch_flag_o <= `Branch;
										next_inst_in_delayslot_o <= `InDelaySlot;
									end
							end
							`EXE_BLTZ: begin // bltz rs, offset
									wreg_o <= `WriteDisable;
									aluop_o <= `EXE_BGEZAL_OP;
									alusel_o <= `EXE_RES_JUMP_BRANCH;
									reg1_read_o <= 1'b1;
									reg2_read_o <= 1'b0;
									instvalid <= `InstValid;
									if(reg1_o[31] == 1'b1) begin
										branch_target_address_o <= pc_plus_4 + imm_sll2_signedext;
										branch_flag_o <= `Branch;
										next_inst_in_delayslot_o <= `InDelaySlot;
									end
							end
							`EXE_BLTZAL: begin // bltzal rs, offset
									wreg_o <= `WriteEnable;
									aluop_o <= `EXE_BGEZAL_OP;
									alusel_o <= `EXE_RES_JUMP_BRANCH;
									reg1_read_o <= 1'b1;
									reg2_read_o <= 1'b0;
									link_addr_o <= pc_plus_8;
									wd_o <= 5'b11111;
									instvalid <= `InstValid;
									if(reg1_o[31] == 1'b1) begin
										branch_target_address_o <= pc_plus_4 + imm_sll2_signedext;
										branch_flag_o <= `Branch;
										next_inst_in_delayslot_o <= `InDelaySlot;
									end
							end

							`EXE_TEQI:   begin
									wreg_o <= `WriteDisable;		
									aluop_o <= `EXE_TEQI_OP;
									alusel_o <= `EXE_RES_NOP; 
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b0;	  	
									imm <= {{16{inst_i[15]}}, inst_i[15:0]};		  	
									instvalid <= `InstValid;	
							end
							`EXE_TGEI:   begin
									wreg_o <= `WriteDisable;		
									aluop_o <= `EXE_TGEI_OP;
									alusel_o <= `EXE_RES_NOP; 
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b0;	  	
									imm <= {{16{inst_i[15]}}, inst_i[15:0]};		  	
									instvalid <= `InstValid;	
							end
							`EXE_TGEIU:   begin
									wreg_o <= `WriteDisable;		
									aluop_o <= `EXE_TGEIU_OP;
									alusel_o <= `EXE_RES_NOP; 
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b0;	  	
									imm <= {{16{inst_i[15]}}, inst_i[15:0]};		  	
									instvalid <= `InstValid;	
							end
							`EXE_TLTI:   begin
									wreg_o <= `WriteDisable;		
									aluop_o <= `EXE_TLTI_OP;
									alusel_o <= `EXE_RES_NOP; 
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b0;	  	
									imm <= {{16{inst_i[15]}}, inst_i[15:0]};		  	
									instvalid <= `InstValid;	
							end
							`EXE_TLTIU:   begin
									wreg_o <= `WriteDisable;		
									aluop_o <= `EXE_TLTIU_OP;
									alusel_o <= `EXE_RES_NOP; 
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b0;	  	
									imm <= {{16{inst_i[15]}}, inst_i[15:0]};		  	
									instvalid <= `InstValid;	
							end
							`EXE_TNEI:   begin
									wreg_o <= `WriteDisable;		
									aluop_o <= `EXE_TNEI_OP;
									alusel_o <= `EXE_RES_NOP; 
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b0;	  	
									imm <= {{16{inst_i[15]}}, inst_i[15:0]};		  	
									instvalid <= `InstValid;	
							end						

							default:   begin
							end
						endcase				
				end

				//branch end-----------------------
				`EXE_SPECIAL2_INST:  begin
						case ( op3 )
							`EXE_CLZ:  begin
									wreg_o <= `WriteEnable;		
									aluop_o <= `EXE_CLZ_OP;
									alusel_o <= `EXE_RES_ARITHMETIC; 
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b0;	  	
									instvalid <= `InstValid;	
							end
							`EXE_CLO:  begin
									wreg_o <= `WriteEnable;		
									aluop_o <= `EXE_CLO_OP;
									alusel_o <= `EXE_RES_ARITHMETIC; 
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b0;	  	
									instvalid <= `InstValid;	
							end
							`EXE_MUL:  begin
									wreg_o <= `WriteEnable;		
									aluop_o <= `EXE_MUL_OP;
									alusel_o <= `EXE_RES_MUL; 
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b1;	
									instvalid <= `InstValid;	  			
							end
							`EXE_MADD:  begin
									wreg_o <= `WriteDisable;		
									aluop_o <= `EXE_MADD_OP;
									alusel_o <= `EXE_RES_MUL; 
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b1;	  			
									instvalid <= `InstValid;	
							end
							`EXE_MADDU:  begin
									wreg_o <= `WriteDisable;		
									aluop_o <= `EXE_MADDU_OP;
									alusel_o <= `EXE_RES_MUL; 
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b1;	  			
									instvalid <= `InstValid;	
							end
							`EXE_MSUB:  begin
									wreg_o <= `WriteDisable;		
									aluop_o <= `EXE_MSUB_OP;
									alusel_o <= `EXE_RES_MUL; 
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b1;	  			
									instvalid <= `InstValid;	
							end
							`EXE_MSUBU:  begin
									wreg_o <= `WriteDisable;		
									aluop_o <= `EXE_MSUBU_OP;
									alusel_o <= `EXE_RES_MUL; 
									reg1_read_o <= 1'b1;	
									reg2_read_o <= 1'b1;	  			
									instvalid <= `InstValid;	
							end				
							default:	begin
							end
						endcase      //EXE_SPECIAL_INST2 case
					end									  	
					default:	begin
					end
			endcase		  //case op
		end			//normal decode
			//check  for SLL,SRL,SRA .their op and op2 is a littile different
			if (inst_i[31:21] == 11'b00000000000) begin
				if (op3 == `EXE_SLL) 	begin
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_SLL_OP;
						alusel_o <= `EXE_RES_SHIFT; 
						reg1_read_o <= 1'b0;	
						reg2_read_o <= 1'b1;	  	
						imm[4:0] <= inst_i[10:6];		
						wd_o <= inst_i[15:11];
						instvalid <= `InstValid;	
				end 
				else if ( op3 == `EXE_SRL )	 begin
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_SRL_OP;
						alusel_o <= `EXE_RES_SHIFT; 
						reg1_read_o <= 1'b0;	
						reg2_read_o <= 1'b1;	  	
						imm[4:0] <= inst_i[10:6];		
						wd_o <= inst_i[15:11];
						instvalid <= `InstValid;	
				end 
				else if ( op3 == `EXE_SRA ) 	begin
						wreg_o <= `WriteEnable;		
						aluop_o <= `EXE_SRA_OP;
						alusel_o <= `EXE_RES_SHIFT; 
						reg1_read_o <= 1'b0;	
						reg2_read_o <= 1'b1;	  	
						imm[4:0] <= inst_i[10:6];		
						wd_o <= inst_i[15:11];
						instvalid <= `InstValid;	
				end
			end	

			//ERET 
			/*
					1.  PC <- EPC, continue running from where the exception occurs
					2.  Status[EXL] <- 0, no longer in exception level
			*/	
			if(inst_i == `EXE_ERET) begin
					wreg_o <= `WriteDisable;		//pc is not a general purpose register
					aluop_o <= `EXE_ERET_OP;
					alusel_o <= `EXE_RES_NOP;   
					reg1_read_o <= 1'b0;	
					reg2_read_o <= 1'b0;
					instvalid <= `InstValid; 
					excepttype_is_eret <= `True_v;				
			end 

			//mtc0, mfc0
			/*
				mtc0 rt, rd  :  cp0[rd] <- reg[rt]  move to c0
				mfc0 rt, rd  :  reg[rd] <- cp0[rt]  move from c0
			*/
		  	if(inst_i[31:21] == 11'b01000000000 && inst_i[10:0] == 11'b00000000000) begin
				aluop_o <= `EXE_MFC0_OP;
				alusel_o <= `EXE_RES_MOVE;
				wd_o <= inst_i[20:16];
				wreg_o <= `WriteEnable;
				instvalid <= `InstValid;	   
				reg1_read_o <= 1'b0;
				reg2_read_o <= 1'b0;		
			end 
			/*else if*/
			if(inst_i[31:21] == 11'b01000000100 && inst_i[10:0] == 11'b00000000000) begin
				aluop_o <= `EXE_MTC0_OP;
				alusel_o <= `EXE_RES_NOP;
				wreg_o <= `WriteDisable;
				instvalid <= `InstValid;	   
				reg1_read_o <= 1'b1;
				reg1_addr_o <= inst_i[20:16];
				reg2_read_o <= 1'b0;					
			end
	end //always, end of all the decode


	//load dependency
	/*
			1.the last instruction is load
			2.that load instrucion's write destination is the same as current decoding instruction's read port

			which indicates that the going-to-be-written value is newer than current regfile
	*/
	//acquire the source opdata, need to solve the data hazard	
	always @ (*) begin
			stallreq_for_reg1_loadrelate <= `NoStop;	
			if(rst == `RstEnable) begin
				reg1_o <= `ZeroWord;	
			end
			else if(pre_inst_is_load == 1'b1 && ex_wd_i == reg1_addr_o && reg1_read_o == 1'b1 ) begin
				stallreq_for_reg1_loadrelate <= `Stop;		//wait for 1 period, stop pc, if, id				
			end
			else if((reg1_read_o == 1'b1) && (ex_wreg_i == 1'b1) && (ex_wd_i == reg1_addr_o)) begin
				reg1_o <= ex_wdata_i; 			//use the newer value
			end
			else if((reg1_read_o == 1'b1) && (mem_wreg_i == 1'b1) && (mem_wd_i == reg1_addr_o)) begin
				reg1_o <= mem_wdata_i; 			
			end
			else if(reg1_read_o == 1'b1) begin
				reg1_o <= reg1_data_i;
			end
			else if(reg1_read_o == 1'b0) begin
				reg1_o <= imm;
			end
			else begin
				reg1_o <= `ZeroWord;
			end
	end
	
	always @ (*) begin
			stallreq_for_reg2_loadrelate <= `NoStop;
			if(rst == `RstEnable) begin
				reg2_o <= `ZeroWord;
			end
			else if(pre_inst_is_load == 1'b1 && ex_wd_i == reg2_addr_o && reg2_read_o == 1'b1 ) begin
				stallreq_for_reg2_loadrelate <= `Stop;			
			end
			else if((reg2_read_o == 1'b1) && (ex_wreg_i == 1'b1) && (ex_wd_i == reg2_addr_o)) begin
				reg2_o <= ex_wdata_i; 
			end
			else if((reg2_read_o == 1'b1) && (mem_wreg_i == 1'b1) && (mem_wd_i == reg2_addr_o)) begin
				reg2_o <= mem_wdata_i;			
			end
			else if(reg2_read_o == 1'b1) begin
				reg2_o <= reg2_data_i;
			end
			else if(reg2_read_o == 1'b0) begin
				reg2_o <= imm;
			end
			else begin
				reg2_o <= `ZeroWord;
			end
	end

	always @ (*) begin
		if(rst == ` RstEnable) begin
			is_in_delayslot_o <= ` NotInDelaySlot;
		end 
		else begin
			is_in_delayslot_o <= is_in_delayslot_i;			//for interrupt use
		end
	end
endmodule
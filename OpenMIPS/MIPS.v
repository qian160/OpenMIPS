`include"def.v"
/*
	about delay slot:
	简单地说就是位于分支指令后面的一条指令，不管分支发生与否其总是被执行，而且位于分支延迟槽中的指令先于分支指令提交 (commit)。
	
	branch:				if	id	ex	mem	wb	
	delay slot:				if	id	ex	mem	wb
	branch target:				if	id	ex	mem	wb
	可以看到delay slot中的指令会先于分支目标处被执行完

	801ea9d4: 02202021 move a0,s1
	801ea9d8: 27a50014 addiu a1,sp,20
	801ea9dc: 0c0ce551 jal 80339544
	801ea9e0: 02403021 move a2,s2	#in delay slot, but help did some useful things
	801ea9e4: 8e240010 lw a0,16(s1)
	...

	MIPS ABI 规定，a0, a1, a2, a3 用于过程调用的前四个参数，则 move a2, s2 是置第 3 个参数，
	但是其位于函数调用指令 jal 80339544（分支指令）之后，
	这个 move a2, s2 所在地即为一个分支延迟槽。

	这种技术手段主要用在早期没有分支预测的流水线 RISC 上。
	引入分支延迟槽的目的主要是为了提高流水线的效率。
	流水线中，分支指令执行时因为确定下一条指令的目标地址（紧随其后 or 跳转目标处？）一般要到第 2 级以后，
	在目标确定前流水线的取指级是不能工作的，即整个流水线就“浪费”（阻塞）了一个时间片，
	为了利用这个时间片，在体系结构的层面上规定跳转指令后面的一个时间片为分支延迟槽（branch delay slot）。
	位于分支延迟槽中的指令总是被执行，与分支发生与否没有关系。这样就有效利用了一个时间片，
	消除了流水线的一个“气泡”。

	现代 RISC 实现早就可以在流水线的第 2 级利用分支预测确定跳转的目标，分支延迟槽也就失去了原来的价值，但为了软件上的兼容性 MIPS 和 SPARC 还是作了保留
	
	早期硬件性能受限，不想浪费一个周期用于bubble，又没有能力支撑分支预测等高级特性，就只好这样了。
	编译器会帮你重新组织代码(这加大了编译器设计难度，设计师气死了)，以用好这个delay slot。(当然，要是代码组织不当，分支槽便会带来预料之外的效果)
	上面的代码就是一个例子

	mfc0 && mtc0 原则上只需要两个操作数就够了，
	但是MIPS32/64架构扩展到了256个寄存器，为了向前兼容，在指令中添加select域来控制多个寄存器。比如
	mtc0 s, $12, 1
	select域的值等于1，其作用就是把通用寄存器s的值写入到协处理器的寄存器12组中的编号为1的寄存器中
	我们没有实现那么多寄存器，一组其实就是一个。select域只要填0即可
*/
module mips(
	input wire 						clk,
	input wire 						rst,

	//读取指令
	input wire[`RegBus]			 	rom_data_i,
	output wire[`RegBus] 			rom_addr_o,
	output wire 					rom_ce_o,

	//Coprocessor 
	input wire[5:0]					int_i,
	output wire   					timer_int_o,

	//数据存储器	
	input wire[`RegBus]           	ram_data_i,
	output wire[`RegBus]           	ram_addr_o,
	output wire[`RegBus]           	ram_data_o,
	output wire                    	ram_we_o,
	output wire[3:0]               	ram_sel_o,
	output wire		               	ram_ce_o
);

	//id -- pc_reg
	wire 					id_branch_flag_o;
	wire[`RegBus] 			branch_target_address;

	// IF/ID  --  ID
	wire[`InstAddrBus] 		pc;
	wire[`InstAddrBus] 		id_pc_i;
	wire[`InstBus]		 	id_inst_i;

	// ID  --  ID/EX, PC_REG
	wire[`AluOpBus] 		id_aluop_o;
	wire[`AluSelBus] 		id_alusel_o;
	wire[`RegBus] 			id_reg1_o;
	wire[`RegBus] 			id_reg2_o;
	wire 					id_wreg_o;
	wire[`RegAddrBus] 		id_wd_o;
	
	wire 					id_is_in_delayslot_o;
 	wire[`RegBus] 			id_link_address_o;

	//这两条是id/ex 和 id之间的交互
	wire 					is_in_delayslot_i;			//id/ex，隔了一个周期后回来告诉id的
	wire 					is_in_delayslot_o;			//当前指令处在delay slot
	
	wire 					next_inst_in_delayslot_o;	//下一条指令处在delay slot，当被传到id/ex后，会被隔一个周期后传回来，完成交互
	wire[`RegBus] 			id_current_inst_address_o;
  	wire[31:0] 				id_excepttype_o;
	//load and store
	wire[15:0] 				id_branch_offset_o;

	// ID/EX  --  EX
	wire[`AluOpBus] 		ex_aluop_i;
	wire[`AluSelBus] 		ex_alusel_i;
	wire[`RegBus] 			ex_reg1_i;
	wire[`RegBus] 			ex_reg2_i;
	wire 					ex_wreg_i;
	wire[`RegAddrBus] 		ex_wd_i;
	wire 					ex_is_in_delayslot_i;	
  	wire[`RegBus] 			ex_link_address_i;
	//load and store, may be optimized to 16-bit offset?
	wire[15:0]	 			ex_branch_offset_i;

  	wire[31:0] 				ex_excepttype_i;	
  	wire[`RegBus] 			ex_current_inst_address_i;	

	// EX  --  EX/MEM
	wire 					ex_wreg_o;
	wire[`RegAddrBus] 		ex_wd_o;
	wire[`RegBus]  			ex_wdata_o;
	wire[`RegBus]   		ex_lo_o;
	wire		 			ex_whilo_o;
	wire [`RegBus] 			ex_hi_o;
	//load and store
	wire[`AluOpBus] 		ex_aluop_o;
	wire[`RegBus] 			ex_mem_addr_o;
	wire[`RegBus] 			ex_reg1_o;		//??
	wire[`RegBus] 			ex_reg2_o;	
	
	wire 					ex_cp0_reg_we_o;
	wire[4:0] 				ex_cp0_reg_write_addr_o;
	wire[`RegBus] 			ex_cp0_reg_data_o; 
	
	wire[31:0] 				ex_excepttype_o;
	wire[`RegBus] 			ex_current_inst_address_o;

	wire 					ex_is_in_delayslot_o;
	
	// EX/MEM  --  MEM
	wire		 			mem_wreg_i;
	wire[`RegAddrBus] 		mem_wd_i;
	wire[`RegBus] 			mem_wdata_i;
	wire[`RegBus] 			mem_hi_i;
	wire[`RegBus] 			mem_lo_i;
	wire 					mem_whilo_i;	
	//load and store
	wire[`AluOpBus] 		mem_aluop_i;
	wire[`RegBus] 			mem_addr_i;
	wire[`RegBus] 			mem_reg1_i;		//???
	wire[`RegBus] 			mem_reg2_i;	

	wire 					mem_cp0_reg_we_i;
	wire[4:0] 				mem_cp0_reg_write_addr_i;
	wire[`RegBus] 			mem_cp0_reg_data_i;

	wire[31:0] 				mem_excepttype_i;	
	wire 					mem_is_in_delayslot_i;
	wire[`RegBus] 			mem_current_inst_address_i;	

	// MEM  --  MEM/WB
	wire 					mem_wreg_o;
	wire[`RegAddrBus] 		mem_wd_o;
	wire[`RegBus]  			mem_wdata_o;
	wire[`RegBus]   		mem_hi_o;
	wire[`RegBus]   		mem_lo_o;
	wire 					mem_whilo_o;	

	wire 					mem_LLbit_value_o;
	wire 					mem_LLbit_we_o;

	wire 					mem_cp0_reg_we_o;
	wire[4:0] 				mem_cp0_reg_write_addr_o;
	wire[`RegBus] 			mem_cp0_reg_data_o;
	
	wire[31:0] 				mem_excepttype_o;
	wire 					mem_is_in_delayslot_o;
	wire[`RegBus] 			mem_current_inst_address_o;			

	// MEM/WB -- WB
	wire 					wb_wreg_i;
	wire[`RegAddrBus] 		wb_wd_i;
	wire[`RegBus] 			wb_wdata_i;
	wire[`RegBus] 			wb_hi_i;
	wire[`RegBus] 			wb_lo_i;
	wire 					wb_whilo_i;	

	wire 					wb_LLbit_value_i;
	wire 					wb_LLbit_we_i;	

	wire 					wb_cp0_reg_we_i;
	wire[4:0] 				wb_cp0_reg_write_addr_i;
	wire[`RegBus] 			wb_cp0_reg_data_i;

	wire[31:0] 				wb_excepttype_i;
	wire 					wb_is_in_delayslot_i;
	wire[`RegBus] 			wb_current_inst_address_i;

	//EX  --  hilo
	wire[`RegBus] 			hi;
	wire[`RegBus]   		lo;

	//ID  --  Regfile
	wire 					reg1_read;
	wire 					reg2_read;
	wire[`RegBus] 			reg1_data;
	wire[`RegBus] 			reg2_data;
	wire[`RegAddrBus] 		reg1_addr;
	wire[`RegAddrBus] 		reg2_addr;

	//ex  --  ex_mem，用于多周期的MADD、MADDU、MSUB、MSUBU指令
	wire[`DoubleRegBus] 	hilo_temp_o;
	wire[1:0] 				cnt_o;
	wire[`DoubleRegBus] 	hilo_temp_i;
	wire[1:0] 				cnt_i;

	//控制相关
	wire[5:0] 				stall;
	wire 					stallreq_from_id;	
	wire 					stallreq_from_ex;

	//除法,ex  --  div
	wire[`DoubleRegBus] 	div_result;
	wire 					div_ready;
	wire[`RegBus] 			div_opdata1;
	wire[`RegBus] 			div_opdata2;
	wire 					div_start;
	wire 					div_annul;
	wire 					signed_div;

	//mem --  LLbit
	wire LLbit_o;
	
	//ex  --  cp0, mfco要用到
	wire[`RegBus] 			cp0_data_o;		
  	wire[4:0] 				cp0_raddr_i;

	//ctrl -- pc_reg
	wire	 				flush;		//不止pc会收到这个
  	wire[`RegBus] 			new_pc;
	
	wire[`RegBus] 			cp0_count;
	wire[`RegBus]			cp0_compare;
	wire[`RegBus]			cp0_status;
	wire[`RegBus]			cp0_cause;
	wire[`RegBus]			cp0_epc;
	wire[`RegBus]			cp0_config;
	wire[`RegBus]			cp0_prid; 

  wire[`RegBus] 			latest_epc;

	// pc_reg例化
	pc_reg pc_reg0(

		.clk(clk), 
		.rst(rst), 
		.pc(pc), 

		.ce(rom_ce_o),
		.branch_flag_i(id_branch_flag_o),
		.branch_target_address_i(branch_target_address),	

		//ctrl	
		.flush(flush),
		.new_pc(new_pc),

		.stall(stall)
	);

	assign rom_addr_o = pc; 

	// IF/ID模块例化
	if_id if_id0(
		.clk(clk), 
		.rst(rst), 
		.if_pc(pc),
		.if_inst(rom_data_i), 
		.id_pc(id_pc_i),
		.id_inst(id_inst_i),

		.flush(flush),

		.stall(stall)
	);

	//ID模块例化
	id id0(
		.rst(rst), 
		.pc_i(id_pc_i), 
		.inst_i(id_inst_i),	

		//form regfile
		.reg1_data_i(reg1_data), 
		.reg2_data_i(reg2_data),

		//to regfile	
		.reg1_read_o(reg1_read), 
		.reg2_read_o(reg2_read),
		.reg1_addr_o(reg1_addr), 
		.reg2_addr_o(reg2_addr),

		.aluop_o(id_aluop_o), 
		.alusel_o(id_alusel_o),
		.reg1_o(id_reg1_o), 
		.reg2_o(id_reg2_o),
		.wd_o(id_wd_o), 
		.wreg_o(id_wreg_o),

		//处于执行阶段的指令要写入的目的寄存器信息,data hazard
		.ex_wreg_i(ex_wreg_o),
		.ex_wdata_i(ex_wdata_o),
		.ex_wd_i(ex_wd_o),

		 //处于访存阶段的指令要写入的目的寄存器信息,data hazard
		.mem_wreg_i(mem_wreg_o),
		.mem_wdata_i(mem_wdata_o),
		.mem_wd_i(mem_wd_o),

		.ex_aluop_i(ex_aluop_o),  //load dependency

		.next_inst_in_delayslot_o(next_inst_in_delayslot_o),	
		.branch_flag_o(id_branch_flag_o),
		.branch_target_address_o(branch_target_address),       
		.link_addr_o(id_link_address_o),
		
		.is_in_delayslot_o(id_is_in_delayslot_o),
		.is_in_delayslot_i(is_in_delayslot_i),

		.excepttype_o(id_excepttype_o),
		.current_inst_address_o(id_current_inst_address_o),

		.id_branch_offset_o(id_branch_offset_o),
		
		.stallreq(stallreq_from_id)
	);

	// 通用寄存器Regfile模块例化
	regfile regfile1(
		.clk (clk), 
		.rst (rst),
		.we(wb_wreg_i), 
		.waddr(wb_wd_i),
		.wdata(wb_wdata_i), 
		.re1(reg1_read),
		.raddr1(reg1_addr), 
		.rdata1(reg1_data),
		.re2(reg2_read), 
		.raddr2(reg2_addr),
		.rdata2(reg2_data)
	);

	// ID/EX模块例化
	id_ex id_ex0(
		.clk(clk), 
		.rst(rst),

		// 从译码阶 段ID模块传递过来的信息
		.id_aluop(id_aluop_o), 
		.id_alusel(id_alusel_o),
		.id_reg1(id_reg1_o), 
		.id_reg2(id_reg2_o),
		.id_wd(id_wd_o), 
		.id_wreg(id_wreg_o),
		
		.id_excepttype(id_excepttype_o),
		.id_current_inst_address(id_current_inst_address_o),
		
		// 传递到EX模块的信息
		.ex_aluop(ex_aluop_i), 
		.ex_alusel(ex_alusel_i),
		.ex_reg1(ex_reg1_i), 
		.ex_reg2(ex_reg2_i),
		.ex_wd(ex_wd_i), 
		.ex_wreg(ex_wreg_i),

		.id_link_address(id_link_address_o),
		.id_is_in_delayslot(id_is_in_delayslot_o),
		.next_inst_in_delayslot_i(next_inst_in_delayslot_o),	

		.ex_link_address(ex_link_address_i),
  		.ex_is_in_delayslot(ex_is_in_delayslot_i),
		.is_in_delayslot_o(is_in_delayslot_i),
		
		.ex_excepttype(ex_excepttype_i),
		.ex_current_inst_address(ex_current_inst_address_i),	

		.branch_offset_i(id_branch_offset_o),	
		.branch_offset_o(ex_branch_offset_i),
		
		.stall(stall)

	);

	// EX模块例化
	ex ex0(
		.rst(rst),

		.aluop_i(ex_aluop_i), 
		.alusel_i(ex_alusel_i),
		.reg1_i(ex_reg1_i), 
		.reg2_i(ex_reg2_i),
		.wd_i(ex_wd_i), 
		.wreg_i(ex_wreg_i),

		//获取hilo的数据，先拿来再说。可能用不到
		.hi_i(hi),
		.lo_i(lo),

		//关于是否要使用hilo的信息。配合多选器来挑选真正的操作数
	 	.wb_hi_i(wb_hi_i),
	  	.wb_lo_i(wb_lo_i),
	  	.wb_whilo_i(wb_whilo_i),
	  	.mem_hi_i(mem_hi_o),
	  	.mem_lo_i(mem_lo_o),
	  	.mem_whilo_i(mem_whilo_o),

		//和多周期指令有关
		.hilo_temp_i(hilo_temp_i),
		.cnt_i(cnt_i),
		.hilo_temp_o(hilo_temp_o),
		.cnt_o(cnt_o),

	      	//输出到EX/MEM模块信息
		.wd_o(ex_wd_o),
		.wreg_o(ex_wreg_o),
		.wdata_o(ex_wdata_o),

		.hi_o(ex_hi_o),
		.lo_o(ex_lo_o),
		.whilo_o(ex_whilo_o),

		.div_opdata1_o(div_opdata1),
		.div_opdata2_o(div_opdata2),
		.div_start_o(div_start),
		.signed_div_o(signed_div),	
		.div_result_i(div_result),
		.div_ready_i(div_ready), 

		.link_address_i(ex_link_address_i),
		.is_in_delayslot_i(ex_is_in_delayslot_i),	

		//load store	
		.ex_branch_offset_i(ex_branch_offset_i),
		.aluop_o(ex_aluop_o),
		.mem_addr_o(ex_mem_addr_o),
		.reg2_o(ex_reg2_o),

		//data hazard
		.mem_cp0_reg_we(mem_cp0_reg_we_o),
		.mem_cp0_reg_write_addr(mem_cp0_reg_write_addr_o),
		.mem_cp0_reg_data(mem_cp0_reg_data_o),
	
		//回写阶段的指令是否要写CP0，用来检测数据相关
		.wb_cp0_reg_we(wb_cp0_reg_we_i),
		.wb_cp0_reg_write_addr(wb_cp0_reg_write_addr_i),
		.wb_cp0_reg_data(wb_cp0_reg_data_i),

		//communicate with cp0
		.cp0_reg_data_i(cp0_data_o),
		.cp0_reg_read_addr_o(cp0_raddr_i),
		
		//向下一流水级传递，用于写CP0中的寄存器
		.cp0_reg_we_o(ex_cp0_reg_we_o),
		.cp0_reg_write_addr_o(ex_cp0_reg_write_addr_o),
		.cp0_reg_data_o(ex_cp0_reg_data_o),	  
		
		.excepttype_i(ex_excepttype_i),
		.current_inst_address_i(ex_current_inst_address_i),

		.excepttype_o(ex_excepttype_o),
		.is_in_delayslot_o(ex_is_in_delayslot_o),
		.current_inst_address_o(ex_current_inst_address_o),		//精确异常	

		.stallreq(stallreq_from_ex)
	);
	
	// EX/MEM模块例化
	ex_mem ex_mem0(
		.clk(clk), 
		.rst(rst),
		.flush(flush),

		// 来自执行阶 段EX模块的信息
		.ex_wd(ex_wd_o), 
		.ex_wreg(ex_wreg_o),
		.ex_wdata(ex_wdata_o),
		.ex_hi(ex_hi_o),
		.ex_lo(ex_lo_o),
		.ex_whilo(ex_whilo_o),

		// 送到访存阶 段MEM模块的信息
		.mem_wd(mem_wd_i), 
		.mem_wreg(mem_wreg_i),
		.mem_wdata(mem_wdata_i),
		.mem_hi(mem_hi_i),
		.mem_lo(mem_lo_i),
		.mem_whilo(mem_whilo_i),

		//for multiple-period  instructions
		.hilo_o(hilo_temp_i),
		.hilo_i(hilo_temp_o),
		.cnt_i(cnt_o),	
		.cnt_o(cnt_i),

		.ex_aluop(ex_aluop_o),
		.ex_mem_addr(ex_mem_addr_o),
		.ex_reg2(ex_reg2_o),
		.mem_aluop(mem_aluop_i),
		.mem_addr(mem_addr_i),
		.mem_reg2(mem_reg2_i),

		.ex_cp0_reg_we(ex_cp0_reg_we_o),
		.ex_cp0_reg_write_addr(ex_cp0_reg_write_addr_o),
		.ex_cp0_reg_data(ex_cp0_reg_data_o),	

		.mem_cp0_reg_we(mem_cp0_reg_we_i),
		.mem_cp0_reg_write_addr(mem_cp0_reg_write_addr_i),
		.mem_cp0_reg_data(mem_cp0_reg_data_i),

		.ex_excepttype(ex_excepttype_o),
		.ex_is_in_delayslot(ex_is_in_delayslot_o),
		.ex_current_inst_address(ex_current_inst_address_o),	

		.mem_excepttype(mem_excepttype_i),
		.mem_is_in_delayslot(mem_is_in_delayslot_i),
		.mem_current_inst_address(mem_current_inst_address_i),

		.stall(stall)
	);

	// MEM模块例化
	mem mem0(
		.rst(rst),
		//from EX/MEM
		.wd_i(mem_wd_i), 
		.wreg_i(mem_wreg_i),
		.wdata_i(mem_wdata_i),
		.hi_i(mem_hi_i),
		.lo_i(mem_lo_i),
		.whilo_i(mem_whilo_i),
		//to MEM/WB
		.wd_o(mem_wd_o), 
		.wreg_o(mem_wreg_o),
		.wdata_o(mem_wdata_o),
		.hi_o(mem_hi_o),
		.lo_o(mem_lo_o),
		.whilo_o(mem_whilo_o),

		//load and store, arithmetic
		.aluop_i(mem_aluop_i),
		.mem_addr_i(mem_addr_i),
		.reg2_i(mem_reg2_i),
	
		//from memory
		.mem_data_i(ram_data_i),

		//to memory
		.mem_addr_o(ram_addr_o),
		.mem_we_o(ram_we_o),
		.mem_sel_o(ram_sel_o),
		.mem_data_o(ram_data_o),
		.mem_ce_o(ram_ce_o),

		//直接获取到的LLbit，但可能不是最新的	
		.LLbit_i(LLbit_o),
		//data hazard for LLbit
		.wb_LLbit_we_i(wb_LLbit_we_i),
		.wb_LLbit_value_i(wb_LLbit_value_i),

		.LLbit_we_o(mem_LLbit_we_o),
		.LLbit_value_o(mem_LLbit_value_o),

		//直接获取到的cp0，同样可能不是最新的,mfc0用 
		.cp0_status_i(cp0_status),
		.cp0_cause_i(cp0_cause),

		//data hazard for cp0，这是ex段的mfc0指令的操作数
		//mem，wb段可能有更新的数据
		.cp0_reg_we_i(mem_cp0_reg_we_i),
		.cp0_reg_write_addr_i(mem_cp0_reg_write_addr_i),
		.cp0_reg_data_i(mem_cp0_reg_data_i),
		
		.wb_cp0_reg_we(wb_cp0_reg_we_i),
		.wb_cp0_reg_write_addr(wb_cp0_reg_write_addr_i),
		.wb_cp0_reg_data(wb_cp0_reg_data_i),	  

		//是否要修改cp0以及相关信息
		//mtco用
		.cp0_reg_we_o(mem_cp0_reg_we_o),
		.cp0_reg_write_addr_o(mem_cp0_reg_write_addr_o),
		.cp0_reg_data_o(mem_cp0_reg_data_o),
		
		.excepttype_i(mem_excepttype_i),
		.is_in_delayslot_i(mem_is_in_delayslot_i),
		.current_inst_address_i(mem_current_inst_address_i),	
		
		.cp0_epc_i(cp0_epc),
		.cp0_epc_o(latest_epc),			//异常发生处

		.excepttype_o(mem_excepttype_o),
		.is_in_delayslot_o(mem_is_in_delayslot_o),
		.current_inst_address_o(mem_current_inst_address_o)		

	);
	
	// MEM/WB模块例化
	mem_wb mem_wb0(
		.clk(clk), 
		.rst(rst),
		.flush(flush),

		// 来自访存阶 段MEM模块的信息
		.mem_wd(mem_wd_o), 
		.mem_wreg(mem_wreg_o),
		.mem_wdata(mem_wdata_o),
		.mem_hi(mem_hi_o),
		.mem_lo(mem_lo_o),
		.mem_whilo(mem_whilo_o),	
		// 送到回写阶 段的信息
		.wb_wd(wb_wd_i), 
		.wb_wreg(wb_wreg_i),
		.wb_wdata(wb_wdata_i),
		.wb_hi(wb_hi_i),
		.wb_lo(wb_lo_i),
		.wb_whilo(wb_whilo_i),

		.mem_LLbit_we(mem_LLbit_we_o),
		.mem_LLbit_value(mem_LLbit_value_o),

		.mem_cp0_reg_we(mem_cp0_reg_we_o),
		.mem_cp0_reg_write_addr(mem_cp0_reg_write_addr_o),
		.mem_cp0_reg_data(mem_cp0_reg_data_o),

		.wb_cp0_reg_we(wb_cp0_reg_we_i),
		.wb_cp0_reg_write_addr(wb_cp0_reg_write_addr_i),
		.wb_cp0_reg_data(wb_cp0_reg_data_i),

		.stall(stall)
	);

	hilo_reg hilo_reg0(
		.clk(clk),
		.rst(rst),
	
		//写端口
		.we(wb_whilo_i),
		.hi_i(wb_hi_i),
		.lo_i(wb_lo_i),
	
		//读端口1
		.hi_o(hi),
		.lo_o(lo)	
	);

	ctrl ctrl0(
		.rst(rst),
		.flush(flush),
		.new_pc(new_pc),

		.stallreq_from_id(stallreq_from_id),
		.stallreq_from_ex(stallreq_from_ex),
		
		.excepttype_i(mem_excepttype_o),
		.cp0_epc_i(latest_epc),

		.stall(stall)       	
	);

	div div0(
		.clk(clk),
		.rst(rst),
	
		.signed_div_i(signed_div),
		.opdata1_i(div_opdata1),
		.opdata2_i(div_opdata2),
		.start_i(div_start),
		.annul_i(flush),
	
		.result_o(div_result),
		.ready_o(div_ready)
	);

	LLbit_reg LLbit_reg0(
		.clk(clk),
		.rst(rst),
	  	.flush(flush),
	  
		//写端口
		.LLbit_i(wb_LLbit_value_i),
		.we(wb_LLbit_we_i),
	
		//读端口1
		.LLbit_o(LLbit_o)
	
	);

	cp0_reg cp0_reg0(
		.clk(clk),
		.rst(rst),
		
		.we_i(wb_cp0_reg_we_i),
		.waddr_i(wb_cp0_reg_write_addr_i),
		.raddr_i(cp0_raddr_i),
		.data_i(wb_cp0_reg_data_i),
		
		.excepttype_i(mem_excepttype_o),
		.int_i(int_i),
		.current_inst_addr_i(mem_current_inst_address_o),
		.is_in_delayslot_i(mem_is_in_delayslot_o),
		
		.data_o(cp0_data_o),
		
		.count_o(cp0_count),
		.compare_o(cp0_compare),
		.status_o(cp0_status),
		.cause_o(cp0_cause),
		.epc_o(cp0_epc),
		.config_o(cp0_config),
		.prid_o(cp0_prid),
		
		.timer_int_o(timer_int_o)  			
	);

endmodule
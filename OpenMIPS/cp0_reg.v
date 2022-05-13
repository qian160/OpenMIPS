`include "def.v"
//only implement some of the registers
/*
        根据访存阶段给出的最终异常类型，修改cp0寄存器的相应位置
*/
module cp0_reg(

	input	wire				    clk,
	input wire			   		    rst,
	
	
	input wire                      we_i,
	input wire[4:0]                 waddr_i,
	input wire[4:0]                 raddr_i,
	input wire[`RegBus]             data_i,
	
	input wire[31:0]                excepttype_i,
	input wire[5:0]                 int_i,
	input wire[`RegBus]             current_inst_addr_i,
	input wire                      is_in_delayslot_i,
	
	output reg[`RegBus]             data_o,     //读出的某个reg的值
	output reg[`RegBus]             count_o,       //下面的都是内部的状态寄存器，可以作为端口输出
	output reg[`RegBus]             compare_o,
	output reg[`RegBus]             status_o,
	output reg[`RegBus]             cause_o,
	output reg[`RegBus]             epc_o,
	output reg[`RegBus]             config_o,
	output reg[`RegBus]             prid_o,
	
	output reg                      timer_int_o    
	
);

	always @ (posedge clk) begin
		if(rst == `RstEnable) begin
                count_o <= `ZeroWord;
                compare_o <= `ZeroWord;
                //status寄存器的CU为0001，表示协处理器CP0存在
                status_o <= 32'b00010000000000000000000000000000;
                cause_o <= `ZeroWord;
                epc_o <= `ZeroWord;
                //config寄存器的BE为1，表示Big-Endian；MT为00，表示没有MMU
                config_o <= 32'b00000000000000001000000000000000;
                //制作者是Q，对应的是0x51，类型是0x1，基本类型，版本号是1.0(自定义)
                prid_o <= 32'b00000000010100010000000100000010;
                timer_int_o <= `InterruptNotAssert;
	    end 
        else begin
                count_o <= count_o + 1 ;
                cause_o[15:10] <= int_i;
		
                if(compare_o != `ZeroWord && count_o == compare_o) begin
                    timer_int_o <= `InterruptAssert;
                end
                        
                if(we_i == `WriteEnable) begin
                    case (waddr_i) 
                        `CP0_REG_COUNT:   begin
                            count_o <= data_i;
                        end
                        `CP0_REG_COMPARE:	begin
                            compare_o <= data_i;
                            //count_o <= `ZeroWord;
                            timer_int_o <= `InterruptNotAssert;
                        end
                        `CP0_REG_STATUS:	begin
                            status_o <= data_i;
                        end
                        `CP0_REG_EPC:	begin
                            epc_o <= data_i;
                        end
                        `CP0_REG_CAUSE:	begin
                        //cause寄存器只有IP[1:0]、IV、WP字段是可写的
                            cause_o[9:8] <= data_i[9:8];
                            cause_o[23] <= data_i[23];
                            cause_o[22] <= data_i[22];
                        end					
                    endcase  //case addr_i
                end

                case (excepttype_i)
                    32'h00000001:   begin           //外部中断
                        if(is_in_delayslot_i == `InDelaySlot ) begin
                            epc_o <= current_inst_addr_i - 4 ;
                            cause_o[31] <= 1'b1;        //BD, Branch Delayslot
                        end 
                        else begin
                            epc_o <= current_inst_addr_i;
                            cause_o[31] <= 1'b0;
                        end
                        
                        status_o[1] <= 1'b1;
                        cause_o[6:2] <= 5'b00000;
                        
                    end
                    32'h00000008:   begin         //syscall
                        if(status_o[1] == 1'b0) begin       //EXL
                            if(is_in_delayslot_i == `InDelaySlot ) begin
                                epc_o <= current_inst_addr_i - 4 ;
                                cause_o[31] <= 1'b1;
                            end 
                            else begin
                                epc_o <= current_inst_addr_i;
                                cause_o[31] <= 1'b0;        //BD
                            end
                        end
                            //当前已处于异常级，这时又发生了新的异常,只需将异常原因保存到Cause
                            //此处设置为syscall
                            //status_o[1] <= 1'b1;
                            cause_o[6:2] <= 5'b01000;			
                    end
                    32'h0000000a:   begin           //invalid instruction
                        if(status_o[1] == 1'b0) begin
                            if(is_in_delayslot_i == `InDelaySlot ) begin
                                epc_o <= current_inst_addr_i - 4 ;
                                cause_o[31] <= 1'b1;
                            end 
                            else begin
                                epc_o <= current_inst_addr_i;
                                cause_o[31] <= 1'b0;
                            end
                        end
                        status_o[1] <= 1'b1;
                        cause_o[6:2] <= 5'b01010;					
                    end
                    32'h0000000d:   begin           //自陷, 自己使用了trap指令
                        if(status_o[1] == 1'b0) begin
                            if(is_in_delayslot_i == `InDelaySlot ) begin
                                epc_o <= current_inst_addr_i - 4 ;
                                cause_o[31] <= 1'b1;
                            end 
                            else begin
                                epc_o <= current_inst_addr_i;
                                cause_o[31] <= 1'b0;
                            end
                        end
                        status_o[1] <= 1'b1;
                        cause_o[6:2] <= 5'b01101;					
                    end
                    32'h0000000c:   begin           //overflow
                        if(status_o[1] == 1'b0) begin
                            if(is_in_delayslot_i == `InDelaySlot ) begin
                                epc_o <= current_inst_addr_i - 4 ;
                                cause_o[31] <= 1'b1;
                            end 
                            else begin
                                epc_o <= current_inst_addr_i;
                                cause_o[31] <= 1'b0;
                            end
                        end
                        status_o[1] <= 1'b1;
                        cause_o[6:2] <= 5'b01100;					
                    end				
                    32'h0000000e:   begin           //eret，treat as a kind of exception
                        status_o[1] <= 1'b0;        //EXL
                        status_o[0] <= 1'b1;        //IE
                    end
                    default:		   begin
                    end
            endcase	
			
		end    //else
	end      //always
			
	always @ (*) begin
		if(rst == `RstEnable) begin
			    data_o <= `ZeroWord;
		end 
        else begin
				case (raddr_i) 
					`CP0_REG_COUNT:   begin
						data_o <= count_o ;
					end
					`CP0_REG_COMPARE:	begin
						data_o <= compare_o ;
					end
					`CP0_REG_STATUS:	begin
						data_o <= status_o ;
					end
					`CP0_REG_CAUSE:	begin
						data_o <= cause_o ;
					end
					`CP0_REG_EPC:	begin
						data_o <= epc_o ;
					end
					`CP0_REG_PrId:	begin
						data_o <= prid_o ;
					end
					`CP0_REG_CONFIG:  begin
						data_o <= config_o ;
					end	
					default: 	begin
					end			
				endcase  //case addr_i			
		end    //else
	end      //always

endmodule
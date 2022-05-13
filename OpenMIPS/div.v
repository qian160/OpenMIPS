`include "def.v"
module div(

	input wire		    				clk,
	input wire							rst,
	
	input wire                          signed_div_i,
	input wire[31:0]                    opdata1_i,
	input wire[31:0]		   			opdata2_i,
	input wire                          start_i,
	input wire                          annul_i,        //cancel
	
	output reg[63:0]                    result_o,
	output reg			                ready_o
);

    /*   finate state machine
    
        1.DivFree       0 
        2.DivByZero 	1
        3.DivOn         2
        4.DivEnd        3

    */

	wire[32:0]  div_temp;           //saves the result here
	reg[5:0]    cnt;
	reg[64:0]   dividend;           //[63:32]:minuend   [k:0]:medium processed value. [31:k+1] unprocessed value.
	//32 + 1 +32 = 65, one bit reserved for lower temp shift
	reg[1:0]    state;
	reg[31:0]   divisor;	    
	reg[31:0]   temp_op1;           //op1 after modified        
	reg[31:0]   temp_op2;

    //最高位用于判断大小, 
	assign div_temp = {1'b0,dividend[63:32]} - {1'b0,divisor};

	always @ (posedge clk) begin
		if (rst == `RstEnable) begin
			state <= `DivFree;
			ready_o <= `DivResultNotReady;
			result_o <= {`ZeroWord,`ZeroWord};
		end 

        else begin
		    case (state)
		  	    `DivFree:       begin               //DivFree状态
                  /*
                        get ready for the DivOn state, do some prepration work
                  */
		  	    	if(start_i == `DivStart && annul_i == 1'b0) begin
		  	    		if(opdata2_i == `ZeroWord) begin
		  				    state <= `DivByZero;
		  			    end 
                        //everything is okay, so we are going to boost the div stage
                        else begin
		  				    state <= `DivOn;
    		  				cnt <= 6'b000000;
                            //signed division  -->  use the absolute value first, after the result is out,modify the sign
    		  				if(signed_div_i == 1'b1 && opdata1_i[31] == 1'b1 ) begin
		  					    temp_op1 = ~opdata1_i + 1;
    		  				end 
                            else begin
		  					    temp_op1 = opdata1_i;
    		  				end
		  				    if(signed_div_i == 1'b1 && opdata2_i[31] == 1'b1 ) begin
		  				    	temp_op2 = ~opdata2_i + 1;
		  				    end
                            else begin
		  			    		temp_op2 = opdata2_i;
		  			    	end
                            //initial value
		  			    	dividend <= {`ZeroWord,`ZeroWord};
                            dividend[32:1] <= temp_op1;     //32:1?????
                            divisor <= temp_op2;
                        end
                    end 

                    else begin   
                    //we are not going to start yet, because no signal is received  
						ready_o <= `DivResultNotReady;
						result_o <= {`ZeroWord,`ZeroWord};
				    end          	
		        end

		  	    `DivByZero:		begin               //DivByZero状态
         	            dividend <= {`ZeroWord,`ZeroWord};
                        state <= `DivEnd;		 		
		  	    end

		  	    `DivOn:		begin               //DivOn状态
		  		    if(annul_i == 1'b0) begin
		  		    	if(cnt != 6'b100000) begin
                            if(div_temp[32] == 1'b1) begin
                            //in line 35, divisor and dividend's highest bit is both set to 0
                            //0 - 0 get 1, which indicates that the minuend is larger than the dividend and we can't sub this
                                dividend <= {dividend[63:0] , 1'b0};
                            end 

                            else begin
                                dividend <= {div_temp[31:0] , dividend[31:0] , 1'b1};
                            end
                            cnt <= cnt + 1;
                        end 

                        else begin
                            //div finished, now consider modifiying the result's sign
                            if((signed_div_i == 1'b1) && ((opdata1_i[31] ^ opdata2_i[31]) == 1'b1)) begin
                                dividend[31:0] <= (~dividend[31:0] + 1);
                            end
                            if((signed_div_i == 1'b1) && ((opdata1_i[31] ^ dividend[64]) == 1'b1)) begin              
                                dividend[64:33] <= (~dividend[64:33] + 1);
                            end

                            state <= `DivEnd;
                            cnt <= 6'b000000;            	
                        end
		  		
                    end 

                    else begin
		  			    state <= `DivFree;
		  		    end	
		  	    end

					//result_o的高32位存储余数，低32位存储商，
					//设置输出信号ready_o为DivResultReady，表示除法结束，然后等待EX模块
					//送来DivStop信号，当EX模块送来DivStop信号时，DIV模块回到DivFree状态

				`DivEnd:	begin               
        	        result_o <= {dividend[64:33], dividend[31:0]};  
                    ready_o <= `DivResultReady;
                    if(start_i == `DivStop) begin
          	            state <= `DivFree;
					    ready_o <= `DivResultNotReady;
					    result_o <= {`ZeroWord,`ZeroWord};       	
                    end		  	
		  	    end

		    endcase
		end
	end

endmodule
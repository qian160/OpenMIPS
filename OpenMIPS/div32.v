module div32(
        input clk,rst_n,
        input start,
        input [31:0] a, 
        input [31:0] b,
        output done,
        output [31:0] yshang,
        output [31:0] yyushu
); 


		assign start = 1;

		reg[63:0] dividend;
		reg[63:0] divisor;
		reg[63:0] reminder;
		reg[5:0] i = 6'h0;
		reg[31:0] quotient;
		reg done_r = 0;

		//set i
		always @(posedge clk or negedge rst_n)begin
			if(rst_n) i <= 6'd0;
			else if(start && i < 6'd33 && !done_r) i <= i + 1'b1; 
			else i <= 6'd0;
		end


		initial #2000 $stop();
	
		//set done
		always @(posedge clk or negedge rst_n)
			if(rst_n) done_r <= 1'b0;
			else if(i == 6'd33) done_r <= 1'b1; 
			//else if(i == 6'd33) done_r <= 1'b0;       

		assign done = done_r;

		wire [31:0] reminder_dividend;

		assign reminder_dividend = dividend;
		//calculate
		always@(*) reminder <= reminder_dividend;

		always @ (posedge clk or negedge rst_n)begin
			if(rst_n) begin
				dividend <= 64'h0;
				divisor <= 64'h0;
				quotient <= 32'h00000000;
				reminder <= 64'h00000000;
			end
			else if(start && !done_r) begin
				if(i == 6'd0) begin
					dividend <= {32'h00000000,{a}};
					divisor <= {{b},32'h00000000}; 
					quotient <= 32'h00000000;
				end
				else begin
					if(reminder < divisor ) begin
						quotient <= quotient << 1;
					end

					else  begin
						reminder <= reminder - divisor;
						quotient <= (quotient << 1) + 1;
					end
					divisor <= divisor >> 1;
				end
			end
		end

		assign yshang = quotient;
		assign yyushu = reminder[31:0];
		
endmodule



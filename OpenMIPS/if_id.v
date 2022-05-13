`include"def.v"
module if_id(
	input wire 					clk,
	input wire 					rst,
	//����ȡָ�� �ε��źţ����к궨��InstBus��ʾָ���ȣ�Ϊ32
	input wire[`InstAddrBus] 	if_pc,
	input wire[`InstBus] 		if_inst,
	input wire [5:0] 			stall,

	input wire     				flush,

	//��Ӧ����� �ε��ź�
	output reg[`InstAddrBus] 	id_pc,
	output reg[`InstBus] 		id_inst
);
	always @ (posedge clk) begin
		if (rst == `RstEnable) begin
			id_pc <= `ZeroWord; 
			id_inst <= `ZeroWord; 
		end

		//��1����stall[1]ΪStop��stall[2]ΪNoStopʱ����ʾȡָ�� ����ͣ��
		// ������� �μ���������ʹ�ÿ�ָ����Ϊ��һ�����ڽ�������� �ε�ָ��
		//��2����stall[1]ΪNoStopʱ��ȡָ�� �μ�����ȡ�õ�ָ���������� ��
		//��3����������£���������� �εļĴ���id_pc��id_inst����

		if(flush == 1'b1)  begin
				id_pc <= `ZeroWord;
				id_inst <=`ZeroWord;
		end

		else if(stall[1] == `Stop && stall[2] == `NoStop) begin
			id_pc <= `ZeroWord;		//stop inst fetch,give empty inst
			id_inst <= `ZeroWord;
		end 
		else if(stall[1] == `NoStop) begin		
			id_pc <= if_pc;
			id_inst <= if_inst;
		end
	end
endmodule
`include"def.v"
module inst_rom(
	input wire ce,
	input wire[`InstAddrBus] addr,
	output reg[`InstBus] inst
);

	// ����һ�����飬��С��InstMemNum��Ԫ�ؿ����InstBus
	reg[`InstBus] inst_mem[0:`InstMemNum-1];
	initial $readmemh ( "inst_rom.data", inst_mem );
	
	always @ (*) begin
		if (ce == `ChipDisable) begin	// ����λ�ź���Чʱ����������ĵ�ַ������ָ��洢��ROM�ж�Ӧ��Ԫ��
			inst <= `ZeroWord;
		end 
		else begin
			inst <= inst_mem[addr[`InstMemNumLog2+1:2]];
		end
	end
endmodule
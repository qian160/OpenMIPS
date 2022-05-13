`include"def.v"
module inst_rom(
	input wire ce,
	input wire[`InstAddrBus] addr,
	output reg[`InstBus] inst
);

	// 定义一个数组，大小是InstMemNum，元素宽度是InstBus
	reg[`InstBus] inst_mem[0:`InstMemNum-1];
	initial $readmemh ( "inst_rom.data", inst_mem );
	
	always @ (*) begin
		if (ce == `ChipDisable) begin	// 当复位信号无效时，依据输入的地址，给出指令存储器ROM中对应的元素
			inst <= `ZeroWord;
		end 
		else begin
			inst <= inst_mem[addr[`InstMemNumLog2+1:2]];
		end
	end
endmodule
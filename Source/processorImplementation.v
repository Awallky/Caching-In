/*
	- Pipelined Source code courtesy of Hank Dietz
	- Modified by Adam Walls, Seifalla Moustafa, Austin Langton
	- Implements a hyperthreaded, 5-stage pipelined processor 
	  with a direct-mapped cache implementation and a memory module 
	  simulating a delay in loading data from main memory.

	***Notes about cache:
	   - Valid === If something from memory has been put into the cache line
	   - Dirty === When CPU writes to the memory, but the cache contains old, obsolete data
	   - Not Dirty === When memory writes to the cache
	   - Cache line will contain {validBit, DirtyBit, instr/data address, instr/data } totalling 34 bits
	   - As things are retrieved from memory, place them into the ir[pid] AND into the cache
	   - Instruction cache is ALWAYS clean
	   - Data cache on the other hand, is not
*/

// basic sizes of things
`define WORD	  	  [15:0]
`define DOUBLE_WORD	  [31:0]
`define BYTE	  	  [7:0]
`define Opcode	  	  [15:12]
`define Immed	  	  [11:0]
`define OP	  	  [7:0]
`define PRE	  	  [3:0]
`define REGSIZE   	  [511:0] 			// 256 for each PID
`define REGNUM	  	  [7:0]
`define MEMSIZE   	  [65535:0]
`define PID	  	  [1:0]
`define MEMDELAY  	  4

// cache sizes and locations
`define CACHE_SIZE 	  8
`define CACHE_BLOCK_SIZE  34				// valid, dirty bit, instr/data addr

`define CACHE_ELEMENTS	  [`CACHE_SIZE-1:0]	
`define CACHE_BLOCK	  [`CACHE_BLOCK_SIZE-1:0]	// [33:0] {valid, dirty, addr, instr/data}

`define CACHE_DATA 	  [15:0]
`define CACHE_ADDR 	  [31:16]
`define CACHE_DIRTY_BIT	  [32]
`define CACHE_VALID_BIT	  [33]

// bool values
`define FALSE		  0
`define TRUE		  1
// dirty bit
`define NOT_DIRTY	  0
`define DIRTY		  1
// valid bit
`define NOT_VALID	  0
`define VALID	 	  1
// rnotw signal
`define READ 		  1
`define WRITE		  0

// opcode values hacked into state numbers
`define OPAdd	{4'h0, 4'h0}
`define OPSub	{4'h0, 4'h1}
`define OPTest	{4'h0, 4'h2}
`define OPLt	{4'h0, 4'h3}

`define OPDup	{4'h0, 4'h4}
`define OPAnd	{4'h0, 4'h5}
`define OPOr	{4'h0, 4'h6}
`define OPXor	{4'h0, 4'h7}

`define OPLoad	{4'h0, 4'h8}
`define OPStore {4'h0, 4'h9}

`define OPRet	{4'h0, 4'ha}
`define OPSys	{4'h0, 4'hb}

`define OPPush	{4'h1, 4'h0}

`define OPCall	{4'h4, 4'h0}
`define OPJump	{4'h5, 4'h0}
`define OPJumpF {4'h6, 4'h0}
`define OPJumpT {4'h7, 4'h0}

`define OPGet	{4'h8, 4'h0}
`define OPPut	{4'h9, 4'h0}
`define OPPop	{4'ha, 4'h0}
`define OPPre	{4'hb, 4'h0}

`define OPNOP	   {4'hc, 4'h0}
`define OPINSTWAIT {4'hd, 4'h0}
`define INSTWAIT   16'hd000
`define LOAD       16'h0008
`define STORE      16'h0009

`define NOREG   255

/* ***************************************** PROCESSOR IMPLEMENTATION ************************************ */
module processor(halt, reset, clk);
	output 		  halt;
	input 		  reset, clk;

	reg  `WORD   	  r `REGSIZE; 			// [15:0] r [511:0]
	reg  `WORD   	  m `MEMSIZE;			// [15:0] m [65535:0]
	reg  `WORD   	  pc `PID;				// [15:0] pc [1:0]
	wire `OP     	  op;				// [7:0] op
	reg  `OP     	  s0op, s1op, s2op;		// [7:0] s0op, s1op, s2op
	reg  `REGNUM 	  sp `PID;			// [7:0] sp [1:0]
	reg  `REGNUM 	  s0d, s1d, s2d, s0s, s1s;	// [7:0] s0d, s1d, s2d, s0s, s1s
	reg  `WORD   	  s0immed, s1immed, s2immed;	// [15:0] s0immed, s1immed, s2immed
	reg  `WORD   	  s1sv, s1dv, s2sv, s2dv;	// [15:0] s1sv, s1dv, s2sv, s2dv
	reg  `WORD   	  ir `PID;			// [15:0] ir [1:0]
	reg  `WORD   	  immed;				// [15:0] immed
	wire         	  teststall, retstall, writestall;
	reg  `PID    	  torf, preset, halts;		// [1:0] torf, preset, halts
	reg  `PRE    	  pre `PID;			// [3:0] pre [1:0]
	reg          	  pid;
	
	// Memory objects
	wire         	  mfc;
	wire `WORD   	  rdata;			// [15:0] rdata
	reg  `WORD   	  wdata;			// [15:0] wdata
	reg          	  rnotw, strobe;
	reg  `WORD   	  addr;				// [15:0] raddr
	wire `WORD	  addrOut;			// [15:0] addrOut	  
	reg  `PID    	  instWait, strobeSent;		// [1:0]  loadInst
	wire `BYTE   	  pend;
	reg          	  getInstrPid;
	reg          	  ldSt;
	reg          	  ld;
	reg  `BYTE   	  prevInstr;
	reg  [9:0]  	  ldReg;
	reg  `WORD	  i;
	
	// Cache Objects
	reg  `CACHE_BLOCK instrCache `CACHE_ELEMENTS; 	// [33:0] cache [7:0]
	reg  `CACHE_BLOCK dataCache  `CACHE_ELEMENTS; 	// [33:0] cache [7:0]
	
	reg               cacheHit, cacheDirty;


	always @(posedge reset) begin
	  sp[0] 	<= 0;
	  sp[1] 	<= 0;
	  pc[0] 	<= 0;
	  pc[1] 	<= 16'h8000;
	  halts[0] 	<= `FALSE;
	  halts[1] 	<= `FALSE;
	  pid 		<= 0;
	  //$readmemh0(r);
	  strobe 	<= `FALSE;
	  strobeSent[0] <= `FALSE;
	  strobeSent[1] <= `FALSE;
	  rnotw 	<= `READ;
	  getInstrPid 	<= 0; 				// process 0 gets the first instruction request
	  ir[0] 	<= `INSTWAIT;
	  ir[1] 	<= `INSTWAIT;
	  ld 		<= `FALSE;
	  ldSt 		<= `FALSE;
	  
	  // Data/Instr. Cache initialization
	  for(i = 0; i < `CACHE_SIZE; i = i + 1) begin
		instrCache[i]`CACHE_DIRTY_BIT <= 1'bx;		// dirty bit set to unkown
		dataCache [i]`CACHE_DIRTY_BIT <= 1'bx;
		
		instrCache[i]`CACHE_VALID_BIT <= `NOT_VALID;			// valid bit set to false
		dataCache [i]`CACHE_VALID_BIT <= `NOT_VALID;
		
		instrCache[i] `DOUBLE_WORD <= 32'hxxxxxxxx;	// cache addr/data/instr set to garbage
		dataCache [i] `DOUBLE_WORD <= 32'hxxxxxxxx;				
	  end
	end // end reset block
	
	// instantiate memory module
	// I: addr, wdata, rnotw, strobe, clk
	// O: mfc, rdata
	slowmem mem(.mfc(mfc), .rdata(rdata), .addrOut(addrOut), .pend(pend), .addr(addr), 
		    .wdata(wdata), .rnotw(rnotw), .strobe(strobe), .clk(clk));
	
	// determine pid
	// Determine which process gets an instruction 
	// (s (0.5) )
	always@(posedge clk) begin
		pid <= !pid;
	/* 
		  	  $display("pid: %d, ir: %x, getInstrPid: %d, strobe: %d, addr: %x, pend: %d, rdata: %x, mfc: %d, strobeSent[pid]: %d", pid, ir[pid], getInstrPid, strobe, addr, pend, rdata, mfc, strobeSent[pid]);

	*/
	
		$display("pc[pid]: %x, op: %x", pc[pid], op);
		
		if( !ld && !ldSt ) begin
			if(s2op == `LOAD) begin
				/* NOTE: have raddr from memory module output for storage in cache block */
				/*  CHECK CACHE FOR DATA HERE AND IN s2 SIMULTANEOUSY */
				// IF s2sv, i.e. the target address is in the data cache
			 	if(cacheHit) begin
					ld <= `FALSE; strobeSent <= `FALSE; strobe <= `FALSE;
					ir[pid] <= `INSTWAIT;
				end // cache miss, load request
				else begin
					ir[pid] <= `INSTWAIT; ld <=`TRUE ; strobeSent[pid] <= `TRUE;	 // load instr flags set
					strobe <= `TRUE; rnotw <= `READ; 				 // load request
				end
				ldSt <= `TRUE;
			end
			else if(ir[pid] == `STORE) begin
				/* CHECK TO SEE IF YOU ARE WRITING NEW DATA IN MEMORY ADDRESS WHICH IS CONTAINED IN THE CACHE */
			 	ir[pid] <= `INSTWAIT; ld <= `FALSE; ldSt <= `TRUE; strobeSent[pid] <= `TRUE;	 	// store instr flags
		 		strobe <= `TRUE; rnotw <= `WRITE; 				 	// store request
				if(cacheDirty) begin
					dataCache[s2dv]`CACHE_DATA      = s2sv; 
					dataCache[s2dv]`CACHE_DIRTY_BIT = `NOT_DIRTY;
					dataCache[s2dv]`CACHE_VALID_BIT = `VALID;
				end
			end
			else if( pid == getInstrPid &&  !halts[pid] && ir[pid] == `INSTWAIT  && !ld && !ldSt ) begin
				// No load instruction request sent
				if( !strobeSent[pid] ) begin
					/* CHECK CACHE FOR ADDRESS FOR INSTRUCTION BEFORE REQUESTING INSTRUCTION FROM MEMORY */
					for(i = 0; i < `CACHE_SIZE; i = i + 1) begin	
						if(instrCache[i]`CACHE_ADDR == pc[pid] &&
						   instrCache[i]`CACHE_VALID_BIT == `VALID) begin
							$display("Valid instruction cache hit");
							cacheHit = `TRUE;
							ir[pid] <= instrCache[i]`CACHE_DATA;
							i = `CACHE_SIZE;
						end
						else begin
							cacheHit = `FALSE;
						end
					end
					if(cacheHit) begin
						strobe <= `FALSE; strobeSent[pid] <= `FALSE;
					end
					else begin
						strobe <= `TRUE; rnotw <= `READ; strobeSent[pid] <= `TRUE; addr <= pc[pid]; // send new load request
					end
				end // load request sent, need to cancel strobe
				else if( (strobeSent[pid] || strobeSent[!pid])  && !mfc ) begin
					strobe <= `FALSE; // wait for the instruction, turn off new load request
				end
				else if( strobeSent[pid] && mfc ) begin
					ir[pid] <= rdata; strobeSent[pid] <= `FALSE; getInstrPid <= !getInstrPid; // toggle to allow the other process to request an instruction
				end // PREFETCH
				else if(strobeSent == 2'b00    && 
					ld         == `FALSE   && 
					strobe     == `FALSE   &&
					s2op       != `OPLoad  &&
					s2op	   != `OPStore) begin
						
					$display("PREFETCHING!!!");
				end
				else begin
					$display("No IDEA how we got here.");
				end
			end
			else if( !halts[!pid] && (getInstrPid == !pid) && mfc ) begin
				ir[!pid] <= rdata; strobeSent[!pid] <= `FALSE; getInstrPid <= !getInstrPid; // toggle to allow the other process to request an instruction
				/* PLACE NEW ADDRESS & INSTRUCTION INTO CACHE */
				instrCache[addrOut]`CACHE_VALID_BIT <= `VALID;
				instrCache[addrOut]`CACHE_DIRTY_BIT <= `NOT_DIRTY;
				instrCache[addrOut]`CACHE_ADDR	    <= addrOut;
				instrCache[addrOut]`CACHE_DATA	    <= rdata;
			end
			else if(ir[pid] == `OPSys) begin   end			 // allow Sys call to propagate
			else begin
				ir[pid] <= `INSTWAIT; 				 // not able to request a new instruction yet, wait
			end
		end // turn off strobe, tell ir to wait, look for mfc for load instr, turn off flags when appropriate
		else begin
			// handles loads		
			if(mfc) begin
				r[ldReg] <= rdata; ld <= `FALSE; strobeSent <= 2'b00;
				// loaded from memory, insert {valid,dirty,addr,data} into data cache block
				dataCache[addrOut]`CACHE_VALID_BIT <= `VALID;
				dataCache[addrOut]`CACHE_DIRTY_BIT <= `NOT_DIRTY;
				dataCache[addrOut]`CACHE_ADDR 	   <= addrOut;
				dataCache[addrOut]`CACHE_DATA	   <= rdata;
			end
			strobe <= 0; ir[pid] <= `INSTWAIT; ldSt <= `FALSE;
		end
	end // end always block

	// Instruction fetch interface
	assign op = {(ir[pid] `Opcode), (((ir[pid] `Opcode) == 0) ? ir[pid][3:0] : 4'd0)};
	// Halted?
	assign halt = (halts[0] && halts[1]);
	// Stall for Test?
	assign teststall = (s1op == `OPTest);
	// Stall for Ret?
	assign retstall = (s1op == `OPRet);
	
	// Instruction fetch from INSTRUCTION MEMORY (s0)
	always @(posedge clk) begin
	  // This case statement sets immed register, accounting for pre
	  case (op)
	    `OPPre: begin
	      pre[pid] <= ir[pid] `PRE;
	      preset[pid] <= 1;
	      immed = ir[pid] `Immed;
	    end
	    `OPCall,
	    `OPJump,
	    `OPJumpF,
	    `OPJumpT: begin
		    if (preset[pid]) begin 	    			// if preset of current thread has been set
			immed = {pre[pid], ir[pid] `Immed}; 		// use the pre register and immed values for immed register
			preset[pid] <= 0;
	      end
		  else begin 			    			// Otherwise Take top bits of pc
			immed <= {pc[pid][14:12], ir[pid] `Immed};
	      end
	    end
	    `OPPush: begin
		    if (preset[pid]) begin 	    			// if preset of current thread has been set
			immed = {pre[pid], ir[pid] `Immed}; 		// use the pre register and immed values for immed register
			preset[pid] <= 0;
	      end
		  else begin			    			// Sign extend
			immed = {{4{ir[pid][11]}}, ir[pid] `Immed};
	      end
	    end
	    default:
	      immed = ir[pid] `Immed;
	  endcase

	  // This case statement sets s0immed, pc, s0op, halt
	  case (op)
	    `OPPre: begin
	      s0op <= `OPNOP;
	      pc[pid] <= pc[pid] + 1;
	    end
	    `OPCall: begin
	      s0immed <= pc[pid] + 1;
	      pc[pid] <= immed;
	      s0op <= `OPCall;
	    end
	    `OPJump: begin
	      pc[pid] <= immed;						// get the address
	      s0op <= `OPNOP;
	    end
	    `OPJumpF: begin
	      if (teststall == 0) begin 	 			// if a test is being made, see if the branch is taken
			pc[pid] <= (torf[pid] ? (pc[pid] + 1) : immed);	// if so, get the address; else, get the next instruction
	      end
		  else begin
			pc[pid] <= pc[pid] + 1;
	      end
	      s0op <= `OPNOP;
	    end
	    `OPJumpT: begin
	      if (teststall == 0) begin 	 			// if a test is being made, see if the branch is taken
			pc[pid] <= (torf[pid] ? immed : (pc[pid] + 1));	// if so, get the address; else, get the next instruction
	      end
		  else begin
			pc[pid] <= pc[pid] + 1;
	      end
	      s0op <= `OPNOP;
	    end
	    `OPRet: begin
	      if (retstall) begin					// checks if there is a pipe bubble due to a return opcode
			s0op <= `OPNOP;					// if s1 is doing a return, s0 must wait
	      end
		  else if (s2op == `OPRet) begin			// if s2 is doing a return, s0 must wait
			s0op <= `OPNOP;
			pc[pid] <= s1sv;
	      end
		  else begin
			s0op <= op;
	      end
	    end
	    `OPSys: begin 						// basically idle this thread
	      s0op <= `OPNOP;
	      halts[pid] <= ((s0op == `OPNOP) && (s1op == `OPNOP) && (s2op == `OPNOP));
	      $display("s0op: %x, s1op: %x, s2op: %x", s0op, s1op, s2op); // show the sys call propagate through the pipeline
	    end
	    `OPINSTWAIT: begin 
	      s0op <= op;						// basically idle this thread
	      s0immed <= immed;
	    end
	    default: begin
	      s0op <= op;
	      s0immed <= immed;
	      pc[pid] <= pc[pid] + 1;
	    end
	  endcase
	end

	// Instruction decode (s1)
	// Changes the stack pointer for the previous thread 
	// which has now propogated through to stage 1
	always @(posedge clk) begin
	  case (s0op)
	    `OPAdd,
	    `OPSub,
	    `OPLt,
	    `OPAnd,
	    `OPOr,
	    `OPXor,
	    `OPStore:
	      begin s1d <= sp[!pid]-1; s1s <= sp[!pid]; sp[!pid] <= sp[!pid]-1; end
	    `OPTest:
	      begin s1d <= `NOREG; s1s <= sp[!pid]; sp[!pid] <= sp[!pid]-1; end
	    `OPDup:
	      begin s1d <= sp[!pid]+1; s1s <= sp[!pid]; sp[!pid] <= sp[!pid]+1; end
	    `OPLoad:
	      begin s1d <= sp[!pid]; s1s <= sp[!pid]; end
	    `OPRet:
	      begin s1d <= `NOREG; s1s <= `NOREG; pc[!pid] <= r[{!pid, sp[!pid]}]; sp[!pid] <= sp[!pid]; end
	    `OPPush:
	      begin s1d <= sp[!pid]+1; s1s <= `NOREG; sp[!pid] <= sp[!pid]+1; end
	    `OPCall:
	      begin s1d <= sp[!pid]+1; s1s <= `NOREG; sp[!pid] <= sp[!pid]+1; end
	    `OPGet:
	      begin s1d <= sp[!pid]+1; s1s <= sp[!pid]-(s0immed `REGNUM); sp[!pid] <= sp[!pid]+1; end
	    `OPPut:
	      begin s1d <= sp[!pid]-(s0immed `REGNUM); s1s <= sp[!pid]; end
	    `OPPop:
	      begin s1d <= `NOREG; s1s <= `NOREG; sp[!pid] <= sp[!pid]-(s0immed `REGNUM); end
	    default:
	      begin s1d <= `NOREG; s1s <= `NOREG; end // not a register operation
	  endcase
	  s1op <= s0op;
	  s1immed <= s0immed;
	end

	// Register read (s2)
	always @(posedge clk) begin
	  s2dv <= ((s1d == `NOREG) ? 0 : r[{pid, s1d}]);
	  s2sv <= ((s1s == `NOREG) ? 0 : r[{pid, s1s}]);
	  s2d <= s1d;
	  s2op <= s1op;
	  s2immed <= s1immed;
	end

	// ALU or DATA MEMORY access and write (s3)
	always @(posedge clk) begin
	  case (s2op)
	    `OPAdd: begin r[{!pid, s2d}] <= s2dv + s2sv; end
	    `OPSub: begin r[{!pid, s2d}] <= s2dv - s2sv; end
	    `OPTest: begin torf[!pid] <= (s2sv != 0); end
	    `OPLt: begin r[{!pid, s2d}] <= (s2dv < s2sv); end
	    `OPDup: begin r[{!pid, s2d}] <= s2sv; end
	    `OPAnd: begin r[{!pid, s2d}] <= s2dv & s2sv; end
	    `OPOr: begin r[{!pid, s2d}] <= s2dv | s2sv; end
	    `OPXor: begin r[{!pid, s2d}] <= s2dv ^ s2sv; end
	    `OPLoad: begin
			for(i=0; i < `CACHE_SIZE; i = i + 1) begin
				if(s2sv == dataCache[i]`CACHE_ADDR && 
				   dataCache[i]`CACHE_VALID_BIT == `VALID &&
				   dataCache[i]`CACHE_DIRTY_BIT == `NOT_DIRTY) begin
					
					//$display("Valid Cache Match Found!\npid: %d, dataCache[i]`CACHE_ADDR: %x", pid, dataCache[i][31:16]);
					cacheHit = `TRUE;
					r[{!pid, s2d}] = dataCache[i]`CACHE_DATA;	
					i = `CACHE_SIZE;
				end
				else begin
				   cacheHit = `FALSE;
				end
			end 
			if(cacheHit) begin
				$display("s2 LOAD cache hit!");
			end // cache miss, load request
			else begin
				addr <= s2sv; ldReg <= {!pid, s2d}; 
			end
	    end // strobe, strobeSent, rnotw set in s0
	    `OPStore: begin
				/* CHECK IF CACHE IS DIRTY */
				 addr <= s2dv; wdata <= s2sv; end 	   // strobe, strobeSent, rnotw set in s0
	    `OPPush,
	    `OPCall: begin r[{!pid, s2d}] <= s2immed; end
	    `OPGet,
	    `OPPut: begin r[{!pid, s2d}] <= s2sv; end
	  endcase
	end
endmodule
/* ***************************************** END OF PROCESSOR IMPLEMENTATION ************************************ */

/* ***************************************** MEMORY IMPLEMENTATION ************************************ */
module slowmem(mfc, rdata, addrOut, pend, addr, wdata, rnotw, strobe, clk);
	output reg mfc;			
	output reg `WORD addrOut;	// [15:0] addrOut
	output reg `WORD rdata;		// [15:0] rdata
	input `WORD addr, wdata;	// [15:0] addr, wdata
	input rnotw, strobe, clk;	//
	output reg `BYTE pend;		// [7:0]  pend
	reg `WORD raddr;		
	reg `WORD m `MEMSIZE; 		// [15:0] m [65535:0]

	initial begin
	  pend <= 0;
	  // $readmemh0(m); // for running in icarus cgi interface
	  // $readmemh("./../Test\ Modules/storeProg1.vmem",m); // for running in iverilog
	  // $readmemh("./../Test\ Modules/testProg1.vmem",m);
	   $readmemh("./../Test\ Modules/loadProg1.vmem", m);
	end

	always @(posedge clk) begin
	  	if (strobe && rnotw) begin
	    		// new read request
	    		raddr <= addr;
	    		pend <= `MEMDELAY;
	  	end 
	  	else begin
	    		if (strobe && !rnotw) begin
	      			// do write
	      			m[addr] <= wdata;
	    		end
	    		// pending read?
	    		if (pend) begin
	      			// write satisfies pending read
	      			if ((raddr == addr) && strobe && !rnotw) begin
					rdata <= wdata;
					mfc <= 1;
					pend <= 0;
					addrOut <= raddr;
	      			end 
		  		else if (pend == 1) begin
					// finally ready
					rdata <= m[raddr];
					mfc <= 1;
					pend <= 0;
					addrOut <= raddr;
	      	  		end 
		  		else begin
					pend <= pend - 1;
	      	  		end
	    		end 
	    		else begin
	      			// return invalid data
	      			rdata <= 16'hxxxx;
	      			mfc <= 0;
	      			addrOut <= 16'hxxxx;
	    		end
	  	end
	end
endmodule

/* ***************************************** END OF MEMORY IMPLEMENTATION ************************************ */


module testbench;
	reg reset = 0;
	reg clk = 0;
	wire halted;
	reg [31:0] count;
	processor PE(halted, reset, clk);
	initial begin
	  $dumpfile("dump.txt"); // for running in iverilog
	  //$dumpfile; // for running in icarus cgi interface
	  $dumpvars(0, PE);
	  #10 reset = 1;
	  #10 reset = 0;
	  count = 0; // just in case
	  while (!halted && (count < 500) ) begin
	    #10 clk = 1;
	    #10 clk = 0;
	    count = count + 1;
	   if(count >= 9000) begin
		$display("Count >= 9000.");
	   end
	  end
	  $display("Count: %d", count);
	  if(halted) begin
	   	$display("HALTED!!! Hail SCIENCE!");
	  end
	  $finish;
	end
endmodule

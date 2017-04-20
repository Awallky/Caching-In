// basic sizes of things
`define WORD	  [15:0]
`define BYTE	  [7:0]
`define Opcode	  [15:12]
`define Immed	  [11:0]
`define OP	  [7:0]
`define PRE	  [3:0]
`define REGSIZE   [511:0] 		// 256 for each PID
`define REGNUM	  [7:0]
`define MEMSIZE   [65535:0]
`define PID	  [1:0]
`define MEMDELAY  4
`define CACHESIZE [7:0]

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

`define OPNOP	{4'hc, 4'h0}

`define NOREG   255

/* ***************************************** PROCESSOR IMPLEMENTATION ************************************ */
module processor(halt, reset, clk);
	output halt;
	input reset, clk;

	reg  `WORD   r `REGSIZE; 				// [15:0] r [511:0]
	reg  `WORD   m `MEMSIZE;				// [15:0] m [65535:0]
	reg  `WORD   pc `PID;					// [15:0] pc [1:0]
	wire `OP     op;						// [7:0] op
	reg  `OP     s0op, s1op, s2op;			// [7:0] s0op, s1op, s2op
	reg  `REGNUM sp `PID;					// [7:0] sp [1:0]
	reg  `REGNUM s0d, s1d, s2d, s0s, s1s;	// [7:0] s0d, s1d, s2d, s0s, s1s
	reg  `WORD   s0immed, s1immed, s2immed;	// [15:0] s0immed, s1immed, s2immed
	reg  `WORD   s1sv, s1dv, s2sv, s2dv;	// [15:0] s1sv, s1dv, s2sv, s2dv
	wire `WORD   ir;						// [15:0] ir
	reg  `WORD   immed;						// [15:0] immed
	wire         teststall, retstall, writestall;
	reg  `PID    torf, preset, halts;		// [1:0] torf, preset, halts
	reg  `PRE    pre `PID;					// [3:0] pre [1:0]
	reg          pid;
	
	/*
	// pid-dependent things
	reg	PID0 = (pid); 			// current process ID, i.e. current thread
	reg	PID1 = (!pid); 			// other process ID, i.e. other thread
	reg `WORD PC1 = pc[PID0]; 			// Program counter of the current process/thread
	reg `WORD PC0 = pc[PID1]; 			// Program Counter for the other thread/process
	reg	PRESET0 = preset[PID0];  // Indicates whether the pre register of current thread has been set
	reg	PRESET1 = preset[PID1];  // Indicates whether the pre register of other thread has been set
	reg	PRE0 = pre[PID0]; 	// Pre register for the current thread
	reg	PRE1 = pre[PID1];		// Pre register for the other thread
	reg	TORF0 = torf[PID0];    // tORf register  for the current process/thread
	reg	TORF1 = torf[PID1];    // tORf register  for the other process/thread
	reg `REGNUM SP0	= sp[PID0];			// stack pointer to registers of current process/thread
	reg `REGNUM SP1	= sp[PID1];			// stack pointer to registers of other process/thread
	reg HALT0 = halts[PID0];	// halt status of current thread
	reg	HALT1 = halts[PID1];	// halt status of other thread
	*/

	/*
	// Memory objects
	reg  `WORD cache `CACHESIZE;	// [15:0] cache [7:0]
	wire       mfc;
	wire `WORD rdata;				// [15:0] rdata
	wire `WORD addr, wdata;			// [15:0] addr, wdata
	reg        rnotw, strobe;
	reg  `WORD raddr;				// [15:0] raddr
	
	// begin reading for the first instruction from memory
	// intialize the write data to garbage
	initial begin
		strobe = 1;
		rnotw = 1;
	end
	*/

	// instantiate memory module
	// I: addr, wdata, rnotw, strobe, clk
	// O: mfc, rdata
	//slowmem mem(.mfc(mfc), .rdata(rdata), .addr(addr), .wdata(wdata), .rnotw(rnotw), .strobe(strobe), .clk(clk));

	/* How to determine addr, wdata, rnotw, strobe for slowmem module? */

	// toggle current process/thread signal
	always@(posedge clk) begin
		pid <= !pid;
		//ir <= m[pc[pid]];
	end

	// reset halt input from test bench,
	// both thread's reg stack pointers,
	// both thread's program counters,
	// and both thread's halt statuses
	// then read from vmem0 into the stack registers
	// and from vmem1 into main memory
	always @(posedge reset) begin
	  sp[0] = 0;
	  sp[1] = 0;
	  pc[0] = 0;
	  pc[1] = 16'h8000;
	  halts[0] = 0;
	  halts[1] = 0;
	  pid = 1;
	  $readmemh0(r);
	  $readmemh1(m); // done inside mem module
	end

	// Halted?
	assign halt = (halts[0] && halts[1]);
	// Stall for Test?
	assign teststall = (s1op == `OPTest);
	// Stall for Ret?
	assign retstall = (s1op == `OPRet);

	// Instruction fetch interface
	//   if the opcode is 0, get the bottom 4 bits of the ir
	//   and set them as the bottom four bits of the op register
	//   else get the opcode and set the bottom four bits as 0
	assign ir = m[pc[pid]]; // get instruction for current thread/process
	//assign addr = `PC0;
	//assign ir = (mfc ? rdata : `OPNOP); // get instruction for current thread/process
	assign op = {(ir `Opcode), (((ir `Opcode) == 0) ? ir[3:0] : 4'd0)};

	// Instruction fetch from INSTRUCTION MEMORY (s0)
	always @(posedge clk) begin
	  // This case statement sets immed register, accounting for pre
	  case (op)
	    `OPPre: begin
	      pre[pid] <= ir `PRE;
	      preset[pid] <= 1;
	      immed = ir `Immed;
	    end
	    `OPCall,
	    `OPJump,
	    `OPJumpF,
	    `OPJumpT: begin
		    if (preset[pid]) begin 	    // if preset of current thread has been set
			immed = {pre[pid], ir `Immed}; // use the pre register and immed values for immed register
			preset[pid] <= 0;
	      end
		  else begin 			    // Otherwise Take top bits of pc
			immed <= {pc[pid][14:12], ir `Immed};
	      end
	    end
	    `OPPush: begin
		    if (preset[pid]) begin 	    // if preset of current thread has been set
			immed = {pre[pid], ir `Immed}; // use the pre register and immed values for immed register
			preset[pid] <= 0;
	      end
		  else begin			    // Sign extend
			immed = {{4{ir[11]}}, ir `Immed};
	      end
	    end
	    default:
	      immed = ir `Immed;
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
	      pc[pid] <= immed;					// get the address
	      s0op <= `OPNOP;
	    end
	    `OPJumpF: begin
	      if (teststall == 0) begin 	 		// if a test is being made, see if the branch is taken
			pc[pid] <= (torf[pid] ? (pc[pid] + 1) : immed);	// if so, get the address; else, get the next instruction
	      end
		  else begin
			pc[pid] <= pc[pid] + 1;
	      end
	      s0op <= `OPNOP;
	    end
	    `OPJumpT: begin
	      if (teststall == 0) begin 	 		// if a test is being made, see if the branch is taken
			pc[pid] <= (torf[pid] ? immed : (pc[pid] + 1));	// if so, get the address; else, get the next instruction
	      end
		  else begin
			pc[pid] <= pc[pid] + 1;
	      end
	      s0op <= `OPNOP;
	    end
	    `OPRet: begin
	      if (retstall) begin				// checks if there is a pipe bubble due to a return opcode
			s0op <= `OPNOP;				// if s1 is doing a return, s0 must wait
	      end
		  else if (s2op == `OPRet) begin		// if s2 is doing a return, s0 must wait
			s0op <= `OPNOP;
			pc[pid] <= s1sv;
	      end
		  else begin
			s0op <= op;
	      end
	    end
	    `OPSys: begin 					// basically idle this thread
	      s0op <= `OPNOP;
	      halts[pid] <= ((s0op == `OPNOP) && (s1op == `OPNOP) && (s2op == `OPNOP));
	    end
	    default: begin
	      s0op <= op;
	      s0immed <= immed;
	      pc[pid] <= pc[pid] + 1;
	    end
	  endcase
	end

	// Instruction decode (s1)
	// Changes the stack pointer for the other thread
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
	    `OPLoad: begin r[{!pid, s2d}] <= m[s2sv]; end
	    `OPStore: begin m[s2dv] <= s2sv; end
	    `OPPush,
	    `OPCall: begin r[{!pid, s2d}] <= s2immed; end
	    `OPGet,
	    `OPPut: begin r[{!pid, s2d}] <= s2sv; end
	  endcase
	end
endmodule
/* ***************************************** END OF PROCESSOR IMPLEMENTATION ************************************ */

/* ***************************************** MEMORY IMPLEMENTATION ************************************ */
module slowmem(mfc, rdata, addr, wdata, rnotw, strobe, clk);
	output reg mfc;
	output reg `WORD rdata;
	input `WORD addr, wdata;
	input rnotw, strobe, clk;
	reg [7:0] pend;
	reg `WORD raddr;
	reg `WORD m `MEMSIZE;

	initial begin
	  pend <= 0;
	  $readmemh1(m);
	end

	always @(posedge clk) begin
	  if (strobe && rnotw) begin
	    // new read request
	    raddr <= addr;
	    pend <= `MEMDELAY;
	  end else begin
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
	      end else if (pend == 1) begin
		// finally ready
		rdata <= m[raddr];
		mfc <= 1;
		pend <= 0;
	      end else begin
		pend <= pend - 1;
	      end
	    end else begin
	      // return invalid data
	      rdata <= 16'hxxxx;
	      mfc <= 0;
	    end
	  end
	end
endmodule

/* ***************************************** END OF MEMORY IMPLEMENTATION ************************************ */


module testbench;
	reg reset = 0;
	reg clk = 0;
	wire halted;
	processor PE(halted, reset, clk);
	initial begin
	  $dumpfile;
	  $dumpvars(0, PE);
	  #10 reset = 1;
	  #10 reset = 0;
	  while (!halted) begin
	    #10 clk = 1;
	    #10 clk = 0;
	  end
	  $finish;
	end
endmodule

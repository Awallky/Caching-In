// basic sizes of things
`define WORD	 [15:0]
`define Opcode	 [15:12]
`define Immed	 [11:0]
`define OP		 [7:0]
`define PRE	 	 [3:0]
`define REGSIZE  [511:0] 		// 256 for each PID
`define REGNUM	 [7:0]
`define MEMSIZE  [65535:0]
`define PID		 [1:0]
`define MEMDELAY 4
`define CACHESIZE [7:0]

// pid-dependent things
`define	PID0	(pid) 		// current process ID, i.e. current thread
`define	PID1	(!pid) 		// other process ID, i.e. other thread
`define	PC0	 pc[`PID0] 	// Program counter of the current process/thread
`define	PC1	 pc[`PID1] 	// Program Counter for the other thread/process
`define	PRESET0	 preset[`PID0]  // Indicates whether the pre register of current thread has been set
`define	PRESET1	 preset[`PID1]  // Indicates whether the pre register of other thread has been set
`define	PRE0	 pre[`PID0] 	// Pre register for the current thread
`define	PRE1	 pre[`PID1]	// Pre register for the other thread
`define	TORF0	 torf[`PID0]    // tORf register  for the current process/thread
`define	TORF1	 torf[`PID1]    // tORf register  for the other process/thread
`define	SP0	 sp[`PID0]	// stack pointer to registers of current process/thread
`define	SP1	 sp[`PID1]	// stack pointer to registers of current process/thread
`define HALT0	 halts[`PID0]	// halt status of current thread
`define	HALT1	 halts[`PID1]	// halt status of other thread

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

`define OPNOP	{4'hf, 4'hf}

`define NOREG   255

module processor(halt, reset, clk);
output halt;
input reset, clk;

reg `WORD r `REGSIZE; 			// [15:0] r [511:0]
reg `WORD m `MEMSIZE;			// [15:0] m [65535:0]
reg `WORD pc `PID;			// [15:0] pc [1:0]
wire `OP op;				// [7:0] op
reg `OP s0op, s1op, s2op;		// [7:0] s0op, s1op, s2op
reg `REGNUM sp `PID;			// [7:0] sp [1:0]
reg `REGNUM s0d, s1d, s2d, s0s, s1s;	// [7:0] s0d, s1d, s2d, s0s, s1s
reg `WORD s0immed, s1immed, s2immed;	// [15:0] s0immed, s1immed, s2immed
reg `WORD s1sv, s1dv, s2sv, s2dv;	// [15:0] s1sv, s1dv, s2sv, s2dv
wire `WORD ir;				// [15:0] ir
reg `WORD immed;			// [15:0] immed
wire teststall, retstall, writestall;
reg `PID torf, preset, halts;		// [1:0] torf, preset, halts
reg `PRE pre `PID;			// [3:0] pre [1:0]
reg pid;
reg `WORD cache `CACHESIZE;		// [15:0] cache [7:0]

// reset halt input from test bench,
// both thread's reg stack pointers, 
// both thread's program counters,
// and both thread's halt statuses
// then read from vmem0 into the stack registers
// and from vmem1 into main memory
always @(posedge reset) begin
  halt <= 0;
  `SP0 <= 0;
  `SP1 <= 0;
  `PC0 <= 0;
  `PC1 <= 16'h8000;
  `HALT0 <= 0;
  `HALT1 <= 0;
  pid <= clk;
//  $readmemh0(r);
//  $readmemh1(m);
end

// Halted?
assign halt = (HALT0 && HALT1);
// Stall for Test?
assign teststall = (s1op == `OPTest);
// Stall for Ret?
assign retstall = (s1op == `OPRet);

// Instruction fetch interface
/* 
   if the opcode is 0, get the bottom 4 bits of the ir 
   and set them as the bottom four bits of the op register
   else get the opcode and set the bottom four bits as 0 
 */
assign ir = m[`PC0]; // get instruction for current thread/process
assign op = {(ir `Opcode), (((ir `Opcode) == 0) ? ir[3:0] : 4'd0)}; 

// determine which thread is active using pid register
always@(posedge clk)begin
	  pid <= (clk % 2);
end
																	
// Instruction fetch from INSTRUCTION MEMORY (s0)
always @(posedge clk) begin 
  // This case statement sets immed register, accounting for pre
  case (op)
    `OPPre: begin
      `PRE0 <= ir `PRE;
      `PRESET0 <= 1;
      immed = ir `Immed;
    end
    `OPCall,
    `OPJump,
    `OPJumpF,
    `OPJumpT: begin
	    if (`PRESET0) begin 	    // if preset of current thread has been set
		immed = {`PRE0, ir `Immed}; // use the pre register and immed values for immed register
		`PRESET0 <= 0;
      end 
	  else begin 			    // Otherwise Take top bits of pc
		immed <= {`PC0[14:12], ir `Immed};
      end
    end
    `OPPush: begin
	    if (`PRESET0) begin 	    // if preset of current thread has been set
		immed = {`PRE0, ir `Immed}; // use the pre register and immed values for immed register
		`PRESET0 <= 0;
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
      `PC0 <= `PC0 + 1;
    end
    `OPCall: begin
      s0immed <= `PC0 + 1;
      `PC0 <= immed;
      s0op <= `OPCall;
    end
    `OPJump: begin
      `PC0 <= immed;					// get the address 
      s0op <= `OPNOP;
    end
    `OPJumpF: begin
      if (teststall == 0) begin 	 		// if a test is being made, see if the branch is taken
		`PC0 <= (`TORF0 ? (`PC0 + 1) : immed);	// if so, get the address; else, get the next instruction
      end 
	  else begin
		`PC0 <= `PC0 + 1;
      end
      s0op <= `OPNOP;
    end
    `OPJumpT: begin
      if (teststall == 0) begin 	 		// if a test is being made, see if the branch is taken
		`PC0 <= (`TORF0 ? immed : (`PC0 + 1));	// if so, get the address; else, get the next instruction
      end 
	  else begin
		`PC0 <= `PC0 + 1;
      end
      s0op <= `OPNOP;
    end
    `OPRet: begin 
      if (retstall) begin				// checks if there is a pipe bubble due to a return opcode
		s0op <= `OPNOP;				// if s1 is doing a return, s0 must wait 
      end 
	  else if (s2op == `OPRet) begin		// if s2 is doing a return, s0 must wait 
		s0op <= `OPNOP;
		`PC0 <= s1sv;
      end 
	  else begin
		s0op <= op;
      end
    end
    `OPSys: begin 					// basically idle this thread
      s0op <= `OPNOP;
      HALT0 <= ((s0op == `OPNOP) && (s1op == `OPNOP) && (s2op == `OPNOP));
    end
    default: begin
      s0op <= op;
      s0immed <= immed;
      `PC0 <= `PC0 + 1;
    end
  endcase
end

// Instruction decode (s1)
always @(posedge clk) begin
  case (s0op)
    `OPAdd,
    `OPSub,
    `OPLt,
    `OPAnd,
    `OPOr,
    `OPXor,
    `OPStore:
      begin s1d <= `SP1-1; s1s <= `SP1; `SP1 <= `SP1-1; end // since sp of other thread is incremented, set next stage to sp - 1 
    `OPTest:
      begin s1d <= `NOREG; s1s <= `SP1; `SP1 <= `SP1-1; end
    `OPDup:
      begin s1d <= `SP1+1; s1s <= `SP1; `SP1 <= `SP1+1; end
    `OPLoad:
      begin s1d <= `SP1; s1s <= `SP1; end
    `OPRet:
      begin s1d <= `NOREG; s1s <= `NOREG; `PC1 <= r[{`PID1, `SP1}]; `SP1 <= `SP1-1; end
    `OPPush:
      begin s1d <= `SP1+1; s1s <= `NOREG; `SP1 <= `SP1+1; end
    `OPCall:
      begin s1d <= `SP1+1; s1s <= `NOREG; `SP1 <= `SP1+1; end
    `OPGet:
      begin s1d <= `SP1+1; s1s <= `SP1-(s0immed `REGNUM); `SP1 <= `SP1+1; end
    `OPPut:
      begin s1d <= `SP1-(s0immed `REGNUM); s1s <= `SP1; end
    `OPPop:
      begin s1d <= `NOREG; s1s <= `NOREG; `SP1 <= `SP1-(s0immed `REGNUM); end
    default:
      begin s1d <= `NOREG; s1s <= `NOREG; end // not a register operation
  endcase
  s1op <= s0op;
  s1immed <= s0immed;
end

// Register read (s3)
always @(posedge clk) begin
  s2dv <= ((s1d == `NOREG) ? 0 : r[{`PID0, s1d}]);
  s2sv <= ((s1s == `NOREG) ? 0 : r[{`PID0, s1s}]);
  s2d <= s1d;
  s2op <= s1op;
  s2immed <= s1immed;
end

// ALU or DATA MEMORY access and write (s4)
always @(posedge clk) begin
  case (s2op)
    `OPAdd: begin r[{`PID1, s2d}] <= s2dv + s2sv; end
    `OPSub: begin r[{`PID1, s2d}] <= s2dv - s2sv; end
    `OPTest: begin `TORF1 <= (s2sv != 0); end
    `OPLt: begin r[{`PID1, s2d}] <= (s2dv < s2sv); end
    `OPDup: begin r[{`PID1, s2d}] <= s2sv; end
    `OPAnd: begin r[{`PID1, s2d}] <= s2dv & s2sv; end
    `OPOr: begin r[{`PID1, s2d}] <= s2dv | s2sv; end
    `OPXor: begin r[{`PID1, s2d}] <= s2dv ^ s2sv; end
    `OPLoad: begin r[{`PID1, s2d}] <= m[s2sv]; end
    `OPStore: begin m[s2dv] <= s2sv; end
    `OPPush,
    `OPCall: begin r[{`PID1, s2d}] <= s2immed; end
    `OPGet,
    `OPPut: begin r[{`PID1, s2d}] <= s2sv; end
  endcase
end
endmodule


/* ******************************* NEEDS IMPLEMENTATION ************************** */
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
  $readmemh0(r);
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

/* ******************************* END OF MEMORY IMPLEMENTATION ************************** */


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

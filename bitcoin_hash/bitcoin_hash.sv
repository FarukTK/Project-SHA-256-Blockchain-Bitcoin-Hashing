module bitcoin_hash #(parameter integer NUM_OF_WORDS = 20)(
	input logic        clk, reset_n, start,
	input logic [15:0] message_addr, output_addr,
	output logic        done, mem_clk, mem_we,
	output logic [15:0] mem_addr,
	output logic [31:0] mem_write_data,
	input logic [31:0] mem_read_data);

parameter num_nonces = 16;

// FSM state variables 
enum logic [3:0] {IDLE, READ, PHASE1_BLOCK, PHASE1_COMPUTE, PHASE2_BLOCK, PHASE2_COMPUTE, PHASE3_BLOCK, PHASE3_COMPUTE, WRITE} state;

// Local variables
logic [31:0] w[16];
logic [31:0] message[20];
logic [31:0] h0, h1, h2, h3, h4, h5, h6, h7;
logic [31:0] h0_block1, h1_block1, h2_block1, h3_block1, h4_block1, h5_block1, h6_block1, h7_block1;
logic [31:0] h0_block2, h1_block2, h2_block2, h3_block2, h4_block2, h5_block2, h6_block2, h7_block2;
logic [31:0] a, b, c, d, e, f, g, h;
logic [ 7:0] i, j;
logic [15:0] offset; // in word address
logic        cur_we;
logic [15:0] cur_addr;
logic [31:0] cur_write_data;
int			t, phase, n;
int			nonce_count, clock_wait;
logic [31:0] hout[num_nonces]; //change done by instructor. 

// SHA256 K constants
parameter int k[64] = '{
    32'h428a2f98,32'h71374491,32'hb5c0fbcf,32'he9b5dba5,32'h3956c25b,32'h59f111f1,32'h923f82a4,32'hab1c5ed5,
    32'hd807aa98,32'h12835b01,32'h243185be,32'h550c7dc3,32'h72be5d74,32'h80deb1fe,32'h9bdc06a7,32'hc19bf174,
    32'he49b69c1,32'hefbe4786,32'h0fc19dc6,32'h240ca1cc,32'h2de92c6f,32'h4a7484aa,32'h5cb0a9dc,32'h76f988da,
    32'h983e5152,32'ha831c66d,32'hb00327c8,32'hbf597fc7,32'hc6e00bf3,32'hd5a79147,32'h06ca6351,32'h14292967,
    32'h27b70a85,32'h2e1b2138,32'h4d2c6dfc,32'h53380d13,32'h650a7354,32'h766a0abb,32'h81c2c92e,32'h92722c85,
    32'ha2bfe8a1,32'ha81a664b,32'hc24b8b70,32'hc76c51a3,32'hd192e819,32'hd6990624,32'hf40e3585,32'h106aa070,
    32'h19a4c116,32'h1e376c08,32'h2748774c,32'h34b0bcb5,32'h391c0cb3,32'h4ed8aa4a,32'h5b9cca4f,32'h682e6ff3,
    32'h748f82ee,32'h78a5636f,32'h84c87814,32'h8cc70208,32'h90befffa,32'ha4506ceb,32'hbef9a3f7,32'hc67178f2
};

// Generate request to memory
// for reading from memory to get original message
// for writing final computed has value
assign mem_clk = clk;
assign mem_addr = cur_addr + offset;
assign mem_we = cur_we;
assign mem_write_data = cur_write_data;

// SHA256 hash round
function logic [255:0] sha256_op(input logic [31:0] a, b, c, d, e, f, g, h, w, k);
    logic [31:0] S1, S0, ch, maj, t1, t2; // internal signals
	
	begin
		 S1 = rightrotate(e, 6) ^ rightrotate(e, 11) ^ rightrotate(e, 25);
		 // Student to add remaning code below
		 ch = (e & f) ^ ((~e) & g);
		 t1 = h + S1 + ch + k + w;
		 S0 = rightrotate(a, 2) ^ rightrotate(a, 13) ^ rightrotate(a, 22);
		 maj = (a & b) ^ (a & c) ^ (b & c);
		 t2 = S0 + maj;
		 sha256_op = {t1 + t2, a, b, c, d + t1, e, f, g};
	end
endfunction

// Right Rotation Example : right rotate input x by r
// Lets say input x = 1111 ffff 2222 3333 4444 6666 7777 8888
// lets say r = 4
// x >> r  will result in : 0000 1111 ffff 2222 3333 4444 6666 7777 
// x << (32-r) will result in : 8888 0000 0000 0000 0000 0000 0000 0000
// final right rotate expression is = (x >> r) | (x << (32-r));
// (0000 1111 ffff 2222 3333 4444 6666 7777) | (8888 0000 0000 0000 0000 0000 0000 0000)
// final value after right rotate = 8888 1111 ffff 2222 3333 4444 6666 7777
// Right rotation function
function logic [31:0] rightrotate(input logic [31:0] x,
                                  input logic [ 7:0] r);
   // Student to add function implementation
	rightrotate = (x >> r) | (x << (32-r));

endfunction

// Function for finding the new w[...] values
function logic [31:0] wtnew(logic[7:0] t);
		logic [31:0] s1, s0;
		s0 = rightrotate(w[t-15], 7) ^ rightrotate(w[t-15], 18) ^ (w[t-15] >> 3);
		s1 = rightrotate(w[t-2], 17) ^ rightrotate(w[t-2], 19) ^ (w[t-2] >> 10);
		wtnew = w[t-16] + s0 + w[t-7] + s1;
endfunction

// SHA-256 FSM 
// Get a BLOCK from the memory, COMPUTE Hash output using SHA256 function
// and write back hash value back to memory
always_ff @(posedge clk, negedge reset_n)
	begin
		if (!reset_n)
			begin
				cur_we <= 1'b0;
				offset <= 1'b0; // offset to control how we read/write data
				state <= IDLE;
			end 
		else case (state)
		// Initialize hash values h0 to h7 and a to h, other variables and memory we, address offset, etc
			IDLE: begin 
				if(start)
					begin
						// Student to add rest of the code
					
						// Initialiing hash values
						h0 <= 32'h6a09e667;
						h1 <= 32'hbb67ae85;
						h2 <= 32'h3c6ef372;
						h3 <= 32'ha54ff53a;
						h4 <= 32'h510e527f;
						h5 <= 32'h9b05688c;
						h6 <= 32'h1f83d9ab;
						h7 <= 32'h5be0cd19;
						
						cur_we <= 1'b0;
						cur_addr <= message_addr;
					
						nonce_count <= 0;
						t <= 0;
						j <= 1'b0;
						
						state <= READ;
					end
			end
			
			READ: begin
				// Read all input message words and store in vector array 'w'
				if(offset <= NUM_OF_WORDS)
					begin
						if(offset != 0)
							begin
								message[offset-1] <= mem_read_data;
							end
						
						// Increment memory address to fetch next block
						offset <= offset + 1;
						
						// stay in read memory state until all input message words are read
						state <= READ;
						
					end
				else
					begin
						offset <= 0;
						state <= PHASE1_BLOCK;
					end
			end

			// SHA-256 FSM 
			// Get a BLOCK from the memory, COMPUTE Hash output using SHA256 function    
			// and write back hash value back to memory
			PHASE1_BLOCK: begin
			// Fetch message in 512-bit block size
			// For each of 512-bit block initiate hash value computation
			
				a <= h0;
				b <= h1;
				c <= h2;
				d <= h3;
				e <= h4;
				f <= h5;
				g <= h6;
				h <= h7;
			
				for(i = 0; i < 16; i++)
					begin
						w[i] <= message[i];
					end
					
				state <= PHASE1_COMPUTE;
				
			end
			
			
			// For each block compute hash function
			// Go back to BLOCK stage after each block hash computation is completed and if
			// there are still number of message blocks available in memory otherwise
			// move to WRITE stage
			
			PHASE1_COMPUTE: begin
			
				if(j <= 64)
					begin
						if(j < 16)
							begin
								{a,b,c,d,e,f,g,h} <= sha256_op(a, b, c, d, e, f, g, h, w[j], k[j]);
							end
						else
							begin
								for(int n = 0; n < 15; n++)
									begin
										w[n] <= w[n+1]; // just wires, shift the array
									end
								w[15] <= wtnew(16); // perform word expansion
								
								if(j != 16)
									begin
										{a,b,c,d,e,f,g,h} <= sha256_op(a, b, c, d, e, f, g, h, w[15], k[j-1]);
									end
							end
							
							j <= j + 1;
							state <= PHASE1_COMPUTE;
					end
				else
					begin
						h0 <= h0 + a;
						h1 <= h1 + b;
						h2 <= h2 + c;
						h3 <= h3 + d;
						h4 <= h4 + e;
						h5 <= h5 + f;
						h6 <= h6 + g;
						h7 <= h7 + h;
												
						state <= PHASE2_BLOCK;
					end
			end
		
			// SHA-256 FSM 
			// Get a BLOCK from the memory, COMPUTE Hash output using SHA256 function    
			// and write back hash value back to memory
			PHASE2_BLOCK: begin
			// Fetch message in 512-bit block size
			// For each of 512-bit block initiate hash value computation
			
				a <= h0;
				b <= h1;
				c <= h2;
				d <= h3;
				e <= h4;
				f <= h5;
				g <= h6;
				h <= h7;
			
				if(nonce_count == 0)
					begin
						h0_block1 <= h0;
						h1_block1 <= h1;
						h2_block1 <= h2;
						h3_block1 <= h3;
						h4_block1 <= h4;
						h5_block1 <= h5;
						h6_block1 <= h6;
						h7_block1 <= h7;
					end
					
				for(i = 0; i < 3; i++)
					begin
						w[i] <= message[i+16];
					end
						
				w[3] <= nonce_count; // the nonce 20th word of the message
				w[4] <= 32'h80000000;
				w[5] <= 32'h00000000;
				w[6] <= 32'h00000000;
				w[7] <= 32'h00000000;
				w[8] <= 32'h00000000;
				w[9] <= 32'h00000000;
				w[10] <= 32'h00000000;
				w[11] <= 32'h00000000;
				w[12] <= 32'h00000000;
				w[13] <= 32'h00000000;
				w[14] <= 32'h00000000;
				w[15] <= 32'd640;
				
				j <= 1'b0; // reset the j counter
				state <= PHASE2_COMPUTE;
			end
			
			// For each block compute hash function
			// Go back to BLOCK stage after each block hash computation is completed and if
			// there are still number of message blocks available in memory otherwise
			// move to WRITE stage
			
			PHASE2_COMPUTE: begin
				if(j <= 64)
					begin
						if(j < 16)
							begin
								{a,b,c,d,e,f,g,h} <= sha256_op(a, b, c, d, e, f, g, h, w[j], k[j]);
							end
						else
							begin
								for(int n = 0; n < 15; n++)
									begin
										w[n] <= w[n+1]; // just wires, shift the array
									end
								w[15] <= wtnew(16); // perform word expansion
								
								if(j != 16)
									begin
										{a,b,c,d,e,f,g,h} <= sha256_op(a, b, c, d, e, f, g, h, w[15], k[j-1]);
									end
							end
							
							j <= j + 1;
							state <= PHASE2_COMPUTE;
					end
				else
					begin
						if(j < 66)
							// first skip one clock cycle and allow the h0-h7 to load new value from phase 2
							begin
								h0 <= h0 + a;
								h1 <= h1 + b;
								h2 <= h2 + c;
								h3 <= h3 + d;
								h4 <= h4 + e;
								h5 <= h5 + f;
								h6 <= h6 + g;
								h7 <= h7 + h;
								
								j <= j + 1;
							end
						else
							// next clock cycle save the phase 2 h0-h7 and load the constant default h0-h7
							begin
								h0_block2 <= h0;
								h1_block2 <= h1;
								h2_block2 <= h2;
								h3_block2 <= h3;
								h4_block2 <= h4;
								h5_block2 <= h5;
								h6_block2 <= h6;
								h7_block2 <= h7;
										
								h0 <= 32'h6a09e667;
								h1 <= 32'hbb67ae85;
								h2 <= 32'h3c6ef372;
								h3 <= 32'ha54ff53a;
								h4 <= 32'h510e527f;
								h5 <= 32'h9b05688c;
								h6 <= 32'h1f83d9ab;
								h7 <= 32'h5be0cd19;
								
								clock_wait <= 0;
								state <= PHASE3_BLOCK;
							end
					end
			end
			
			// SHA-256 FSM 
			// Get a BLOCK from the memory, COMPUTE Hash output using SHA256 function    
			// and write back hash value back to memory
			PHASE3_BLOCK: begin
			// Fetch message in 512-bit block size
			// For each of 512-bit block initiate hash value computation
			
				a <= h0;
				b <= h1;
				c <= h2;
				d <= h3;
				e <= h4;
				f <= h5;
				g <= h6;
				h <= h7;
						
				w[0] <= h0_block2;
				w[1] <= h1_block2;
				w[2] <= h2_block2;
				w[3] <= h3_block2;
				w[4] <= h4_block2;
				w[5] <= h5_block2;
				w[6] <= h6_block2;
				w[7] <= h7_block2;
				w[8] <= 32'h80000000;
				w[9] <= 32'h00000000;
				w[10] <= 32'h00000000;
				w[11] <= 32'h00000000;
				w[12] <= 32'h00000000;
				w[13] <= 32'h00000000;
				w[14] <= 32'h00000000;
				w[15] <= 32'd256;
				
				j <= 1'b0; // reset the j counter
				state <= PHASE3_COMPUTE;
				
			end
			
			// For each block compute hash function
			// Go back to BLOCK stage after each block hash computation is completed and if
			// there are still number of message blocks available in memory otherwise
			// move to WRITE stage
			
			PHASE3_COMPUTE: begin
				if(j <= 64)
					begin
						if(j < 16)
							begin
								{a,b,c,d,e,f,g,h} <= sha256_op(a, b, c, d, e, f, g, h, w[j], k[j]);
							end
						else
							begin
								for(int n = 0; n < 15; n++)
									begin
										w[n] <= w[n+1]; // just wires, shift the array
									end
								w[15] <= wtnew(16); // perform word expansion
								
								if(j != 16)
									begin
										{a,b,c,d,e,f,g,h} <= sha256_op(a, b, c, d, e, f, g, h, w[15], k[j-1]);
									end
							end
							
							j <= j + 1;
							state <= PHASE3_COMPUTE;
					end
				else
					begin
						h0 <= h0 + a;
						h1 <= h1 + b;
						h2 <= h2 + c;
						h3 <= h3 + d;
						h4 <= h4 + e;
						h5 <= h5 + f;
						h6 <= h6 + g;
						h7 <= h7 + h;
						state<=WRITE;
			end
	end

	
	// h0 to h7 each are 32 bit hashes, which makes up total 256 bit value
			// h0 to h7 after compute stage has final computed hash value
			// write back these h0 to h7 to memory starting from output_addr
			WRITE: begin

				cur_addr <= output_addr;
				offset <= nonce_count;
				cur_we <= 1;
				cur_write_data <= h0;
				
				if(clock_wait == 0 & nonce_count == 15)
					begin
						clock_wait <= 1;
						state <= WRITE;
					end
				else
					begin
						if(nonce_count < num_nonces-1)
							begin
								nonce_count <= nonce_count + 1;
								
								h0 <= h0_block1;
								h1 <= h1_block1;
								h2 <= h2_block1;
								h3 <= h3_block1;
								h4 <= h4_block1;
								h5 <= h5_block1;
								h6 <= h6_block1;
								h7 <= h7_block1;
								
								state <= PHASE2_BLOCK;
							end
						else
							begin
								cur_we <= 1'b0;
								offset <= 0;
								nonce_count <= 0;
								j <= 0;
								state <= IDLE;
							end
					end
			end
		endcase
		
	end

// Generate done when SHA256 hash computation has finished and moved to IDLE state
assign done = (state == IDLE);

endmodule

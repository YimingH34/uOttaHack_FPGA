/****************************************************************************
FILENAME     :  video_uut.sv
PROJECT      :  Hack-a-Thon 2026
****************************************************************************/

/*  INSTANTIATION TEMPLATE  -------------------------------------------------

video_uut video_uut (       
    .clk_i          ( ),//               
    .cen_i          ( ),// video clock enable
    .rst_i          ( ),//
    .vid_sel_i      ( ),//
    .vid_rgb_i      ( ),//[23:0] = R[23:16], G[15:8], B[7:0]
    .vh_blank_i     ( ),//[ 1:0] = {Vblank, Hblank}
    .dvh_sync_i     ( ),//[ 2:0] = {D_sync, Vsync , Hsync }
    // Output signals
    .dvh_sync_o     ( ),//[ 2:0] = {D_sync, Vsync , Hsync }  delayed
    .vid_rgb_o      ( ) //[23:0] = R[23:16], G[15:8], B[7:0] delayed
);

-------------------------------------------------------------------------- */

module video_uut (
    input  wire         clk_i       ,
    input  wire         cen_i       ,
    input  wire         rst_i       ,
    input  wire         vid_sel_i   ,
    input  wire [23:0]  vid_rgb_i   ,
    input  wire [1:0]   vh_blank_i  ,
    input  wire [2:0]   dvh_sync_i  ,
    output wire [2:0]   dvh_sync_o  ,
    output wire [23:0]  vid_rgb_o    
); 

    // --- 1. SETTINGS & PARAMETERS ---
    localparam H_RES = 1920; 
    localparam V_RES = 1080;
    localparam V_MID = V_RES / 2; 

    // Karen's Colors
    localparam [23:0] BG_COLOR   = 24'h00_00_00; // Black Background
    localparam [23:0] WAVE_COLOR = 24'h00_FF_00; // CRT Green

    // Animation Settings
    localparam LINE_THICKNESS = 6;  // Thickness of the beam (pixels)
    localparam ANIM_SPEED     = 1;  // Lower = Faster updates (0 or 1 is best)

    // State Machine States
    typedef enum logic [1:0] {
        S_IDLE   = 2'd0,
        S_ATTACK = 2'd1,
        S_HOLD   = 2'd2,
        S_DECAY  = 2'd3
    } state_t;

    // --- 2. REGISTERS & SIGNALS ---
    reg [23:0]  vid_rgb_d1;
    reg [2:0]   dvh_sync_d1;
    reg [11:0]  x_cnt;
    reg [11:0]  y_cnt;
    reg         prev_de, prev_vs; 

    // Animation Variables
    state_t     current_state = S_IDLE;
    reg [7:0]   state_timer   = 0;      
    reg [3:0]   global_amp    = 0;      
    reg [3:0]   target_amp    = 0;      
    reg [5:0]   speed_cnt     = 0; 
    
    // 16-bit LFSR for better randomness
    reg [15:0]  lfsr          = 16'hACE1; 

    // Wave Shaping Variables
    reg [15:0]  phase_ofs     = 0; 
    reg [4:0]   freq_1        = 12; // Base frequency (High for Karen look)
    reg [4:0]   freq_2        = 18; 

    // Math Pipeline
    logic [15:0] idx_1, idx_2;       
    logic [7:0]  saw_1, saw_2;       
    logic signed [8:0]  tri_1, tri_2; // -128 to +127
    logic signed [10:0] combined_raw; 
    logic signed [12:0] wave_height;
    logic signed [12:0] target_y; 
    logic signed [3:0]  jitter; // Vertical vibration


    // --- 3. MATH BLOCK (SHARP TRIANGLE WAVE) ---
    
    // A. Indices: Multiply X by Frequency + Phase
    //    We use fairly high multipliers to make the wave "tight"
    assign idx_1 = (x_cnt + phase_ofs) * (freq_1);
    assign idx_2 = (x_cnt + phase_ofs) * (freq_2);

    // B. Sawtooth Extraction (0..255)
    assign saw_1 = idx_1[12:5]; 
    assign saw_2 = idx_2[12:5];

    // C. Triangle Conversion (Absolute Value Logic)
    //    This turns the ramp /|/| into a zig-zag /\/\
    //    Math: If (saw > 127) then (255 - saw) else (saw). Result is 0..127.
    //    Then we subtract 64 to center it at 0 (-64..+63).
    assign tri_1 = (saw_1 > 127) ? (255 - saw_1) - 64 : saw_1 - 64;
    assign tri_2 = (saw_2 > 127) ? (255 - saw_2) - 64 : saw_2 - 64;

    // D. Combine and Scale
    //    We sum the two waves to get interference (irregular peaks).
    assign combined_raw = tri_1 + tri_2;

    // E. Volume Scaling
    //    (Wave * Volume) / 2. 
    //    Dividing by 2 allows for very tall peaks when Volume is 10.
    assign wave_height = (combined_raw * $signed({1'b0, global_amp})) / 2;
    
    // F. Jitter (The "Alive" Hum)
    //    Even when Volume is 0, we add a tiny +/- 1 pixel vibration using LFSR bottom bits.
    //    This makes the flatline look like an active oscilloscope.
    assign jitter   = {1'b0, lfsr[1:0]} - 1; 

    // G. Final Target Y
    assign target_y = $signed(V_MID) + wave_height + jitter;


    // --- 4. MAIN LOGIC LOOP ---
    always @(posedge clk_i) begin
        if(cen_i) begin
            // Shuffle Random Number Generator
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

            // --- ANIMATION UPDATE (Once per frame) ---
            prev_vs <= dvh_sync_i[1];
            
            if (dvh_sync_i[1] && !prev_vs) begin 
                
                if (speed_cnt >= ANIM_SPEED) begin 
                    speed_cnt <= 0;

                    case (current_state)
                        // STATE 1: SILENCE (The Hum)
                        S_IDLE: begin
                            global_amp <= 0;
                            if (state_timer == 0) begin
                                current_state <= S_ATTACK;
                                
                                // Randomize the next "Word"
                                phase_ofs <= lfsr; // Scramble horizontal position
                                
                                // Pick new random Volume (Target Amp)
                                // Only pick loud volumes (4-10) to avoid weak whimpers
                                if (lfsr[3:0] < 4) target_amp <= 5; 
                                else if (lfsr[3:0] > 10) target_amp <= 10;
                                else target_amp <= lfsr[3:0];

                                // Randomize Texture (Frequency)
                                freq_1 <= {1'b0, lfsr[3:0]} + 10; // Base freq 10-25
                                freq_2 <= {1'b0, lfsr[7:4]} + 14; 
                            end
                            else state_timer <= state_timer - 1;
                        end

                        // STATE 2: ATTACK (Grow Fast)
                        S_ATTACK: begin
                            if (global_amp >= target_amp) begin
                                current_state <= S_HOLD;
                                state_timer   <= {lfsr[4:0], 2'b00}; // Hold for random time
                            end
                            else global_amp <= global_amp + 2; // +2 for snappy attack
                        end

                        // STATE 3: HOLD (Talk & Glitch)
                        S_HOLD: begin
                            if (state_timer == 0) current_state <= S_DECAY;
                            else begin
                                state_timer <= state_timer - 1;
                                
                                // Voice Texture Glitching
                                // Every few frames, randomly shift frequency to vibrate the line
                                if (lfsr[1:0] == 2'b11) freq_1 <= freq_1 + 1;
                                
                                // Volume instability (Talk louder/quieter randomly)
                                if (lfsr[2:0] == 3'b000 && target_amp < 10) target_amp <= target_amp + 1;
                                if (lfsr[2:0] == 3'b111 && target_amp > 3)  target_amp <= target_amp - 1;
                                
                                // Glide towards the new jittery target
                                if (global_amp < target_amp) global_amp <= global_amp + 1;
                                if (global_amp > target_amp) global_amp <= global_amp - 1;
                            end
                        end

                        // STATE 4: DECAY (Stop Talking)
                        S_DECAY: begin
                            if (global_amp <= 1) begin // Snap to 0 when close
                                global_amp    <= 0;
                                current_state <= S_IDLE;
                                state_timer   <= {lfsr[5:0], 2'b00}; // Wait random time
                            end
                            else global_amp <= global_amp - 1;
                        end
                    endcase
                end 
                else speed_cnt <= speed_cnt + 1;
            end


            // --- DRAWING LOGIC ---
            prev_de <= dvh_sync_i[2]; 
            
            // X/Y Counters
            if (dvh_sync_i[1]) begin 
                y_cnt <= 0; x_cnt <= 0;
            end 
            else if (dvh_sync_i[2]) begin
                x_cnt <= x_cnt + 1;
            end 
            else if (prev_de && !dvh_sync_i[2]) begin
                y_cnt <= y_cnt + 1; x_cnt <= 0;
            end

            // Pixel Output
            // Check if current Y is within +/- (THICKNESS/2) of Target Y
            if ( (y_cnt >= (target_y - (LINE_THICKNESS/2))) && 
                 (y_cnt <  (target_y + (LINE_THICKNESS/2))) ) 
            begin
                vid_rgb_d1 <= WAVE_COLOR; 
            end 
            else begin
                vid_rgb_d1 <= (vid_sel_i) ? BG_COLOR : vid_rgb_i;
            end

            dvh_sync_d1 <= dvh_sync_i;
        end
    end

    // Output Assignments
    assign dvh_sync_o  = dvh_sync_d1;
    assign vid_rgb_o   = vid_rgb_d1;

endmodule
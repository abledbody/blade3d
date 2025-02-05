local scanlines = userdata("f64",11,270)

---Draws a 3D textured triangle to the screen. Note that the vertices need W components,
---and that they need to be the reciprocal of the W which is produced by the projection matrix.
---This step is typically done in the perspective division step.
---@param props table The properties passed to the shader. Expects a `tex` field with a texture index.
---@param vert_data userdata A 6x3 matrix where each row is the xyzwuv of a vertex.
---@param screen_height number The height of the screen, used for scanline truncation.
return function(props,vert_data,screen_height)
	profile"Triangle drawing"
	local spr = props.tex
	
	-- To make it so that rasterizing top to bottom is always correct,
	-- and so that we know at which point to switch the minor side's slope,
	-- we need the vertices to be sorted by y.
	vert_data:sort(1)
	
	-- These values are used extensively in the setup, so we'll store them in
	-- local variables.
	local x1,y1,w1,u1,v1, y2, x3,y3,w3,u3,v3 =
		vert_data[0],vert_data[1],vert_data[3],vert_data[4],vert_data[5],
		vert_data[7],
		vert_data[12],vert_data[13],vert_data[15],vert_data[16],vert_data[17]
	
	local t = (y2-y1)/(y3-y1)
	local row1 = vert_data:row(0)
	local rowd = (vert_data:row(2)-row1)*t+row1
	local sl1,sl2 = 
		vec(spr,x1,y1,x1,y1,u1,v1,u1,v1,w1,w1),
		vec(
			spr,
			vert_data[6],y2,
			rowd.x, y2,
			vert_data[10],vert_data[11], -- uv2
			rowd[4],rowd[5],
			vert_data[9],rowd[3]
		)
	
	local start_y = y1 < -1 and -1 or y1\1
	local mid_y = y2 < -1 and -1 or y2 > screen_height-1 and screen_height-1 or y2\1
	local stop_y = (y3 <= screen_height-1 and y3\1 or screen_height-1)
	
	-- Top half
	local dy = mid_y-start_y
	if dy > 0 then
		local slope = (sl2-sl1):div((y2-y1))
		
		scanlines:copy(slope*(start_y+1-y1)+sl1,true,0,0,11)
			:copy(slope,true,0,11,11,0,11,dy-1)
		
		tline3d(scanlines:add(scanlines,true,0,11,11,11,11,dy-1),0,dy)
	end
	
	-- Bottom half
	dy = stop_y-mid_y
	if dy > 0 then
		-- This is, otherwise, the only place where sl3 would be used,
		-- so we just inline it.
		local slope = (vec(spr,x3,y3,x3,y3,u3,v3,u3,v3,w3,w3)-sl2)/(y3-y2)
		
		scanlines:copy(slope*(mid_y+1-y2)+sl2,true,0,0,11)
			:copy(slope,true,0,11,11,0,11,dy-1)
			
		tline3d(scanlines:add(scanlines,true,0,11,11,11,11,dy-1),0,dy)
	end
	profile"Triangle drawing"
end
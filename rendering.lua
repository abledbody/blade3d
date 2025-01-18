--[[pod_format="raw",created="2024-05-22 18:18:28",modified="2024-11-06 08:29:04",revision=18461]]
local Utils = require"blade3d.utils"
local Camera = require"blade3d.camera"
local sort = Utils.tab_sort

local draw_queue = {}
local model_queue = {}

local function queue_draw_call(func,z)
	add(draw_queue,{func = func,z = z})
end

---Applies perspective division to a matrix of points.
local function perspective_points(pts)
	local pts_height = pts:height()

	-- Replace the w column with its reciprocals.
	pts.div(1,pts,true,0,3,1,0,4,pts_height)

    -- Unfortunately, we can't do a single operation which uses the same w
    -- twice, so we split it into X and Y.
	return pts:mul(pts,true,3,0,1,4,4,pts_height) -- X
		:mul(pts,true,3,1,1,4,4,pts_height) -- Y
end

---Applies perspective division to a single point.
local function perspective_point(pt)
	local w = 1/pt[3]
	pt = pt:mul(w,false,0,0,3)
	pt[3] = w
	return pt
end

---Draws all render calls in the queue using the current camera.
local function draw_all()
	set_draw_target(Camera.get_active().target)
	
	for pending in all(model_queue) do
		pending()
	end
    
	profile"Z-sorting"
	local sorted = sort(draw_queue,"z",true)
	profile"Z-sorting"
	for draw_command in sorted do
		draw_command.func()
	end
	
	model_queue = {}
	draw_queue = {}
end

---Queues a model for rendering.
---@param model table @The model to queue.
---@param pipeline table @The pipeline to use for this model.
---@vararg any @Per-model arguments to pass to the pipeline.
---@return table @An empty table which indexes to the source model.
local function queue_model(model,pipeline,...)
	local m_reference = {__index = model}
	local model_inst = setmetatable({},m_reference)
	local args = {...}
	add(model_queue,function() pipeline(model_inst,unpack(args)) end)
	return model_inst
end

---Queues a point for rendering.
---@param p userdata @The coordinates of the point.
---@param col integer @The color of the point.
---@param mat userdata @The point's transformation matrix.
local function queue_point(p,col,mat)
	profile"Point queueing"
	p = p:matmul(mat)
	
	local cam = Camera.get_active()
	local relative_cam_pos = p-cam.position
	local depth = relative_cam_pos:dot(relative_cam_pos)
	
	p = p:matmul(cam:get_vp_matrix())
	
	if	   p.z >  p[3]
		or p.z < -p[3]
	then return end

	p = perspective_point(p)
		:mul(cam.cts_mul,true,0,0,3)
		:add(cam.cts_add,true,0,0,3),
	
	add(draw_queue,{
		func = function() pset(p.x,p.y,col) end,
		z = depth
	})
	profile"Point queueing"
end

---Queues multiple points for rendering.
---@param pts userdata @4xN userdata of point coordinates.
---@param col integer @The color of the points.
---@param mat userdata @The point's transformation matrix.
---@param midpoint? userdata @The coodinate used for calculating the depth for sorting. Otherwise calculates depth per point.
local function queue_points(pts,col,mat,midpoint)
	profile"Point queueing"
	local pmodel = pts:matmul(mat)
	local ph = pmodel:height()
	local depth = 1
	
	local cam = Camera.get_active()
	local p = pmodel:matmul(cam:get_vp_matrix())
	
	profile"Frustum tests"
	for i = 0, ph-1 do
		local pt = p:row(i)
		
		-- The other axes are actually not worth culling, too expensive.
		if 	   pt.z >  pt[3]
			or pt.z < -pt[3]  then
			-- Yup, just get that out of the way.
			p:set(0,i,1,0,0,1)
		end
	end	
	profile"Frustum tests"

	p = perspective_points(p:copy(p))
		:mul(cam.cts_mul,true,0,0,3,0,4,ph)
		:add(cam.cts_add,true,0,0,3,0,4,ph)

	if midpoint then
		local relative_cam_pos = midpoint-cam.position
		depth = relative_cam_pos:dot(relative_cam_pos)

		local draws = userdata("f64",3,ph)
			:copy(p,true,0,0,2,4,3,ph)
			:copy(col,true,0,2,1,0,3,ph)
		
		add(draw_queue,{
			func = function()
				pset(draws)
			end,
			z = depth
		})
	else
		local relative_cam_pos = pmodel:sub(cam.position,false,0,0,3,0,4,ph)
		relative_cam_pos:mul(relative_cam_pos,true,0,0,3,4,4,ph)
		local depths = userdata("f64",ph) -- Sum of squares
			:copy(relative_cam_pos,true,0,0,1,4,1,ph)
			:add(relative_cam_pos,true,1,0,1,4,1,ph)
			:add(relative_cam_pos,true,2,0,1,4,1,ph)

		for i = 0,ph-1 do
			local pt = p:row(i)

			add(draw_queue,{
				func = function()
					pset(pt.x,pt.y,col)
				end,
				z = depths[i]
			})
		end
	end

	profile"Point queueing"
end

---Queues a line for rendering.
---@param p1 userdata @The first point of the line.
---@param p2 userdata @The second point of the line.
---@param col integer @The color of the line.
---@param mat userdata @The line's transformation matrix.
local function queue_line(p1,p2,col,mat)
	p1,p2 = p1:matmul(mat),p2:matmul(mat)
	
	local cam = Camera.get_active()
	local relative_cam_pos = (p1+p2)*0.5-cam.position
	local depth = relative_cam_pos:dot(relative_cam_pos)
	
	local vp = cam:get_vp_matrix()
	p1,p2 = p1:matmul(vp),p2:matmul(vp)
	
	if	   p1.z >  p1[3] and p2.z >  p2[3]
		or p1.z < -p1[3] and p2.z < -p2[3]
		or p1.x >  p1[3] and p2.x >  p2[3]
		or p1.x < -p1[3] and p2.x < -p2[3]
		or p1.y >  p1[3] and p2.y >  p2[3]
		or p1.y < -p1[3] and p2.y < -p2[3]
	then return end
	
	if p1.z >  p1[3] or  p2.z > p2[3] then
		-- We'll call the point behind the camera p2.
		if p1.z < p2.z then
			p1, p2 = p2, p1
		end
		
		local diff2 = p2-p1
		p2 = diff2*(p1.z-p1[3])/(diff2.z+diff2[3])+p1
	end

	p1,p2 =
		perspective_point(p1)
			:mul(cam.cts_mul,true,0,0,3)
			:add(cam.cts_add,true,0,0,3),
		perspective_point(p2)
			:mul(cam.cts_mul,true,0,0,3)
			:add(cam.cts_add,true,0,0,3)
	
	add(draw_queue,{
		func = function() line(p1.x,p1.y,p2.x,p2.y,col) end,
		z = depth
	})
end

local function queue_billboard(pt,material,ambience,light,light_intensity)
	local cam = Camera.get_active()
	local relative_cam_pos = pt-cam.position
	
	pt = perspective_point(pt:matmul(cam:get_vp_matrix()))
	
	if pt.z > pt[3] or pt.z < -pt[3] then return end
	
	local depth = relative_cam_pos:dot(relative_cam_pos)
	
	local props = setmetatable({},material)
	if light then
		local light_mag = light:magnitude()+0.00001
		local illuminance = light_intensity
			and light_intensity/(light_mag*light_mag) -- Inverse square falloff
			or light_mag
		
		local relative_dir = relative_cam_pos/-relative_cam_pos:magnitude()
		
		local lum = relative_dir:dot(light/light_mag)
		props.light = (lum > 0 and lum or 0)
			*illuminance
			+ambience
	elseif ambience then
		props.light = ambience
	end
	
	props.size *= pt[3]*cam.target:height()*0.5 --NDC spans -1 to 1.
	pt:mul(cam.cts_mul,true,0,0,3)
		:add(cam.cts_add,true,0,0,3)
	
	add(draw_queue,{
		func = function() material.shader(props,pt) end,
		z = depth
	})
end

return {
	queue_model = queue_model,
	queue_point = queue_point,
	queue_points = queue_points,
	queue_line = queue_line,
	queue_billboard = queue_billboard,
	queue_draw_call = queue_draw_call,
	draw_all = draw_all,
	perspective_points = perspective_points,
	perspective_point = perspective_point,
}
local Culling = require"blade3d.culling"
local backface_cull,frustum_cull = Culling.backfaces,Culling.frustum
local Camera = require"blade3d.camera"
local Rendering = require"blade3d.rendering"
local perspective_points,
	perspective_point,
	queue_draw_call =
	Rendering.perspective_points,
	Rendering.perspective_point,
	Rendering.queue_draw_call

local function point_depths(sorting_points,relative_cam_pos)
	profile"Depth determination"
	-- Here we do a mass operation to determine the distance of each sorting
	-- point to the camera.
	local cam_sort_points = sorting_points:sub(
		relative_cam_pos,false,0,0,3,0,3,sorting_points:height()
	)
	-- Square the components.
	cam_sort_points:mul(cam_sort_points,true)
	
	-- Since this distance is only used in comparisons, we can cheap out and
	-- skip the square root.
	local depths = userdata("f64",cam_sort_points:height())
		:add(cam_sort_points,true,0,0,1,3,1,cam_sort_points:height()) -- X
		:add(cam_sort_points,true,1,0,1,3,1,cam_sort_points:height()) -- Y
		:add(cam_sort_points,true,2,0,1,3,1,cam_sort_points:height()) -- Z
	
	profile"Depth determination"

	return depths
end

local function light_model(norms,imat,ambience,light,light_intensity)
	profile"Lighting"
	local lums
	if light then
		-- For directional lights, the position needs to be stripped from the
		-- inverse matrix.
		local light_pos = light:matmul3d(
			light_intensity and imat or imat:copy(0,false,0,12,3)
		)
		local light_mag = light_pos:magnitude()+0.00001

		local illuminance = light_intensity
			and light_intensity/(light_mag*light_mag) -- Inverse square falloff
			or light_mag
		
		lums = norms:matmul((light_pos/light_mag):transpose()):max(0) -- Normal contribution
			*illuminance -- Intensity
		if ambience then
			lums += ambience -- Ambient light
		end
	elseif ambience then
		lums = userdata("f64",norms:height())
			:copy(ambience,true,0,0,1,0,1,norms:height())
	else
		error("Attempted to apply lighting without a light source or ambient light.")
	end
	profile"Lighting"

	return lums
end

---@param cull_center userdata @The center of the model's bounding sphere.
---@param cull_radius number @The radius of the model's bounding sphere.
---@param mat userdata @The model's transformation matrix.
---@param cam RenderCamera @The camera to check the frustum of.
---@return boolean @Whether the model intersects the frustum.
local function in_frustum(cull_center,cull_radius,mat,cam)
	profile"Model frustum culling"
	-- If we transform the cull center into camera space, the frustum
	-- becomes less mathematically complex to deal with.
	cull_center = cull_center:matmul3d(
		mat:matmul3d(cam:get_view_matrix())
	)
	local depth = -cull_center.z
	
	-- Near and far plane are simple. They're just a depth check.
	local inside = depth > cam.near_plane-cull_radius
		and depth < cam.far_plane+cull_radius
		-- To determine the distance from the sides, we need to use the
		-- scalar rejection from the frustum planes.
		and vec(abs(cull_center.x),depth):dot(cam.frust_norm_x) < cull_radius
		and vec(abs(cull_center.y),depth):dot(cam.frust_norm_y) < cull_radius
	profile"Model frustum culling"
	return inside
end

---@param pts userdata @The model's points.
---@param cam RenderCamera @The camera to use.
---@param mutate boolean @Whether to mutate the input points.
---@return userdata
local function clip_to_screen(pts,cam,mutate)
	return pts:mul(cam.cts_mul,mutate,0,0,3,0,4,pts:height())
		:add(cam.cts_add,true,0,0,3,0,4,pts:height())
end

local function draw_model(model,screen_height)
	local pts,uvs,indices,skip_tris,materials,depths,lums =
			model.pts,model.uvs,model.indices,
			model.skip_tris,model.materials,model.depths,
			model.lums
	
	profile"Model iteration"
	local unpacked_verts = userdata("f64",6,#indices)
	pts:copy(indices,unpacked_verts,0,0,4,1,6,#indices)
	unpacked_verts:copy(uvs,true,0,4,2,2,6,uvs:height())
	
	for j = 0,indices:height()-1 do
		if skip_tris[j] <= 0 then
			local vert_data = userdata("f64",6,3)
				:copy(unpacked_verts,true,j*18,0,18)
			
			local material = materials[j]
			local props_in = setmetatable({light = lums and lums[j]},material)
			
			queue_draw_call(
				function()
					material.shader(props_in,vert_data,screen_height)
				end,
				depths[j]
			)
		end
	end
	profile"Model iteration"
end

local function standard(ambience,light,light_intensity,model,mat,imat)
	local cam = Camera.get_active()
	local cull_center = model.cull_center
	if not in_frustum(cull_center,model.cull_radius,mat,cam) then return end

	local norms,relative_cam_pos = model.norms,cam.position:matmul3d(imat)

	model.skip_tris = backface_cull(norms,model.face_dists,relative_cam_pos)

	model.pts = model.pts:matmul(mat:matmul(cam:get_vp_matrix()))
	model.depths = point_depths(model.sorting_points,relative_cam_pos)
	model.lums = light_model(norms,imat,ambience,light,light_intensity)
	
	local clipped = frustum_cull(model)

	perspective_points(model.pts,true)
	clip_to_screen(model.pts,cam,true)
	
	draw_model(model,cam.target:height())
	
	if (not clipped) then return end

	perspective_points(clipped.pts,true)
	clip_to_screen(clipped.pts,cam,true)

	draw_model(clipped,cam.target:height())
end

return {
	perspective_points = perspective_points,
	perspective_point = perspective_point,
	point_depths = point_depths,
	light_model = light_model,
	in_frustum = in_frustum,
	clip_to_screen = clip_to_screen,
	draw_model = draw_model,
	standard = standard,
}
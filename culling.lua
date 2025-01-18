---Takes a model in clip space, culls triangles that are outside the frustum,
---and clips triangles that intersect the near plane.
---@return table? @A new model containing every clipped triangle.
local function frustum(model)
	local pts,uvs,indices,
		skip_tris,materials,depths,lums =
			model.pts,model.uvs,model.indices,
			model.skip_tris,model.materials,model.depths,model.lums
	
	local tri_clips = {}
	local quad_clips = {}
	for i = 0,indices:height()-1 do
		if skip_tris[i] <= 0 then
			local i1,i2,i3 = indices:get(0,i,3)
			local p1,p2,p3 =
				pts:row(i1/4),
				pts:row(i2/4),
				pts:row(i3/4)
			local w1,w2,w3 = p1[3],p2[3],p3[3]
			
			-- The near clipping plane is the only one that's actually clipped.
			-- Truncation is cheaper on the edges, and culling entire triangles
			-- is cheaper than that.
			local n1,n2,n3 =
				p1.z < 0,
				p2.z < 0,
				p3.z < 0
			
			-- If all three vertices are behind a clipping plane, discard the
			-- triangle.
			if (n1 and n2 and n3)
				or (p1.x < -w1 and p2.x < -w2 and p3.x < -w3)
				or (p1.x >  w1 and p2.x >  w2 and p3.x >  w3)
				or (p1.y < -w1 and p2.y < -w2 and p3.y < -w3)
				or (p1.y >  w1 and p2.y >  w2 and p3.y >  w3)
			then
				skip_tris[i] = 1
				-- If all vertices are in front of the near plane,
				-- we don't need to clip.
			elseif n1 or n2 or n3 then
				
				-- Instead of modifying the existing triangle, we disable this
				-- one and provide a list of new generated ones.
				skip_tris[i] = 1
				local iuv = i*3
				
				-- UVs are per-triangle.
				local uv1,uv2,uv3 =
					uvs:row(iuv),
					uvs:row(iuv+1),
					uvs:row(iuv+2)
				
				-- "Inside" and "outside" referring to the frustum.
				local inside = {}
				local outside = {}
				-- By including the original index of the vertex, we can
				-- determine how to write the new vertices to maintain
				-- the winding order, even though we're scrambling the
				-- order so we know which ones are inside and outside.
				add(n1 and outside or inside, {p1,uv1,1})
				add(n2 and outside or inside, {p2,uv2,2})
				add(n3 and outside or inside, {p3,uv3,3})
				
				-- If two vertices are inside, and one is outside, the cut
				-- is an entirely new edge, so we need a quad. If only one
				-- is inside, the cut is essentially one of the existing
				-- edges. A slightly smaller triangle is enough.
				if #outside == 1 then
					add(
						quad_clips,
						{
							inside[1],inside[2],outside[1],
							materials[i],depths[i],lums and lums[i]
						}
					)
				else
					add(
						tri_clips,
						{
							inside[1],outside[1],outside[2],
							materials[i],depths[i],lums and lums[i]
						}
					)
				end
			end
		end
	end
	
	-- We know ahead of time how many triangles we need to generate, so these
	-- arrays can be made with a fixed size.
	local gen_tri_count = #tri_clips+#quad_clips*2
	if gen_tri_count == 0 then return end
	
	local gen_vert_count = #tri_clips*3+#quad_clips*4
	
	local gen_pts = userdata("f64",4,gen_vert_count)
	local gen_uvs = userdata("f64",2,gen_tri_count*3)
	local gen_indices = userdata("i32",3,gen_tri_count)
	local gen_materials = {}
	local gen_depths = userdata("f64",gen_tri_count)
	local gen_lums = lums and userdata("f64",gen_tri_count)
	
	-- vert_i and tri_i mutate differently for triangles and quads.
	local vert_i = 0
	local tri_i = 0
	for i = 1,#tri_clips do
		local verts = tri_clips[i]
		-- Fetch data. v1 is the inside vertex.
		local v1,v2,v3 = verts[1],verts[2],verts[3]
		
		-- The one case where the winding order as retreived is backwards.
		if v2[3] == 1 and v3[3] == 3 then
			v2,v3 = v3,v2
		end
		
		local p1,p2,p3 = v1[1],v2[1],v3[1]
		local uv1,uv2,uv3 = v1[2],v2[2],v3[2]
		
		-- Deltas are very useful for interpolation.
		local diff2,diff3 = p2-p1,p3-p1

		local t2,t3 =
			-p1.z/diff2.z,
			-p1.z/diff3.z
		
		-- Lerp to get the vertices at the clipping plane.
		p2,p3 = diff2*t2+p1,diff3*t3+p1
		uv2,uv3 = (uv2-uv1)*t2+uv1,(uv3-uv1)*t3+uv1
		
		gen_pts:set(0,vert_i,
			p1[0],p1[1],p1[2],p1[3],
			p2[0],p2[1],p2[2],p2[3],
			p3[0],p3[1],p3[2],p3[3]
		)
		gen_uvs:set(0,tri_i*3,
			uv1[0],uv1[1],
			uv2[0],uv2[1],
			uv3[0],uv3[1]
		)
		local i1 = vert_i*4
		gen_indices:set(0,tri_i,i1,i1+4,i1+8)
		
		-- Copy over the extra data from the original triangle.
		gen_materials[tri_i] = verts[4]
		gen_depths[tri_i] = verts[5]
		if lums then
			gen_lums[tri_i] = verts[6]
		end
		
		vert_i += 3
		tri_i += 1
	end
	
	for i = 1,#quad_clips do
		local verts = quad_clips[i]
		local v1,v2,v3 = verts[1],verts[2],verts[3]
		
		if v1[3] == 1 and v2[3] == 3 then
			v1,v2 = v2,v1
		end
		
		local p1,p2,p3 = v1[1],v2[1],v3[1]
		local uv1,uv2,uv3 = v1[2],v2[2],v3[2]
		
		local diff1,diff2 = p1-p3,p2-p3
		local t1,t2 =
			-p3.z/diff1.z,
			-p3.z/diff2.z
		
		-- We need to generate one extra vertex for the quad.
		local p4 = diff2*t2+p3
		local uv4 = (uv2-uv3)*t2+uv3
		
		p3 = diff1*t1+p3
		uv3 = (uv1-uv3)*t1+uv3
		
		gen_pts:set(0,vert_i,
			p1[0],p1[1],p1[2],p1[3],
			p2[0],p2[1],p2[2],p2[3],
			p3[0],p3[1],p3[2],p3[3],
			p4[0],p4[1],p4[2],p4[3]
		)
		gen_uvs:set(0,tri_i*3,
			uv1[0],uv1[1],
			uv2[0],uv2[1],
			uv3[0],uv3[1],
			
			uv3[0],uv3[1],
			uv2[0],uv2[1],
			uv4[0],uv4[1]
		)
		local i1 = vert_i*4
		local i2,i3,i4 = i1+4,i1+8,i1+12
		gen_indices:set(0,tri_i,
			i1,i2,i3,
			i3,i2,i4
		)
		
		gen_materials[tri_i] = verts[4]
		gen_materials[tri_i+1] = verts[4]
		gen_depths[tri_i] = verts[5]
		gen_depths[tri_i+1] = verts[5]
		if lums then
			gen_lums[tri_i] = verts[6]
			gen_lums[tri_i+1] = verts[6]
		end
		
		vert_i += 4
		tri_i += 2
	end
	
	return {
		pts = gen_pts,
		uvs = gen_uvs,
		indices = gen_indices,
		skip_tris = userdata("f64",gen_tri_count),
		materials = gen_materials,
		depths = gen_depths,
		lums = gen_lums
	}
end

local function backfaces(norms,face_dists,relative_cam_pos)
	profile"Backface culling"
	-- Each face, in addition to a normal, has a length. This length is the
	-- the distance between the origin and the plane that the face sits on, and
	-- can be precomputed. The scalar projection of the camera onto the normal
	-- tells us how far along the normal the camera is from the origin. If this
	-- is less than the face's length, the camera is behind the face.
	
	-- Did you know that multiplying a matrix by a transposed vector is the same
	-- as performing a dot product between the matrix's rows and the vector?
	local dots = norms:matmul(relative_cam_pos:transpose())
	local skips = face_dists-dots
	profile"Backface culling"
	return skips
end

return {
	frustum = frustum,
	backfaces = backfaces
}
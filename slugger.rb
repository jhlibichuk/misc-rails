class Slugger
	require 'cgi'
	require 'uri'
	require 'benchmark'
	# build solr queries piecemeal
	# convert URLs to buildable search queries eg
	# /body_type/sedan/year/1999 -> Slugger.body_type(sedan).year(1999) -> Auto.search with :body_type_id end
	#FACETS
	attr_accessor :parcel_conditions, :term_conditions, :terms, :range_bases, :page, :parcel_riders, :metroslug, :fields
	#FIELDS = {exterior_color: 1.0, make: 2.0, model:1.0, metro: 1.0, city:2.0, new_or_used: 1.0, description: 2.0, body_type: 1.0, dealer: 15.0, options: 1.0}
	FIELDS = {display_make: 2.0, display_model: 1.5, exterior_color: 2.0, make: 2.0, model:2.0, city: 1.0, new_or_used: 1.0, body_type: 2.0, dealer: 215.0, options: 1.0, trim: 2.0}

	def deslug(url)
		#sanitize url ?

		url = url.gsub("/s/","").gsub(/^\/s$/,"").gsub("+"," ")
		@parcel_conditions = @parcel_conditions || Array.new
		@term_conditions = @term_conditions || Array.new

		@fields = FIELDS
		@terms = @terms || Hash.new
		@range_bases = @range_bases || Array.new
		@parcel_riders = Hash.new
		
		# Parcels are the items contained in the friendly URL bit, eg: /body_type/sedan
		parcels = url.split("?")[0]

		# Terms are anything after the ?, eg, ?price_min=5000&price_max=10000
		terms = url.split("?")[1]
		@metroslug = Slugger.deslug_facet(url,"Metro")
		@term_conditions = process_terms(terms,@term_conditions) unless terms.blank?
		@parcel_conditions = process_parcels(parcels,@parcel_conditions) unless parcels.blank?
		@conditions = @parcel_conditions + @term_conditions
		@conditions
	end

	def process_parcels(parcels,conditions)
		parcels = parcels.split("/")
		parcels.reject!(&:empty?)
		parcels.each do |facet|
			condition = process_parcel(facet) #self.send(klass,facet)
			conditions << condition unless condition.blank?
		end
		conditions
	end

	def process_terms(terms,conditions)
		terms = terms.split("&")
		terms.reject!(&:empty?)
		terms.each do |term|
			items = term.split("=")
			item = items[0] unless items.blank?
			facet = items[1] unless items.blank?
			
			item = downsize(item)
			facet = facet.gsub("$","") unless facet.blank?
			facet = "" if facet.blank?	

			if item.include?("year") || item.include?("price") || item.include?("mileage") #FACETS
				# Part of a range.

				if facet.include?("-")
					base = item
				else
					base = item.split("_")[0]
				end
				@range_bases << base
				@terms[item.to_sym] = facet
				# We'll handle these conditions later.
			elsif item.include?("keywords")
				@terms[:keywords] = facet
				#we'll handle this later, too. don't add it to conditions
			else
				# Just a one-off deal. Handle each expected condition individually.
				case item
				when "s"
					conditions << "fulltext '#{facet}'" unless facet.blank?
				when "make", "model","body_type", "purchase_type", "metro", "posted_by" #FACETS
					unless @parcel_riders[item].blank?	
						@parcel_riders[item] << facet
					else
						@parcel_riders[item] = Array.new
						@parcel_riders[item] << facet
					end
				when "outlying"
					if facet == "false"
						conditions << "without(:city_id, Slugger.from_slug('#{@metroslug}').cities.outlying.map(&:id) )"
					end
				when "year", "price", "mileage"
					facet = facet.to_i
					conditions << "with(:#{item}, #{facet})"
				when "dealership"
					dealer = CGI.unescape(facet)
					dealer = Dealer.where("name = ?", dealer).first
      		dealer = dealer.id unless dealer.blank?
      		unless dealer.blank?
						conditions  << "with(:advertiser_id,#{dealer})"
						conditions  << "with(:advertiser_type,'Dealer')"
					end

				else
					# not sure this is a good idea..
					#@terms[item.to_sym] = facet
				end
			end
		end

		for base in @range_bases.uniq
			# we support two styles:
			# ?year-min=199x&year-max=200y
			# ... and ...
			# ?year=199x-200y
			base_sym = base.to_sym
			base_min = "#{base}_min".to_sym
			base_max = "#{base}_max".to_sym
			if @terms[base_min] && @terms[base_max].blank?
				@terms[base_max] = "999999999"
			elsif @terms[base_max] && @terms[base_min].blank?
				@terms[base_min] = "1"
			elsif @terms[base_max] && @terms[base_min]
				#DO IT
			else
				if !@terms[base_sym].blank? && @terms[base_sym].include?("-")
					t_base_min = @terms[base.to_sym].split("-")[0]
					t_base_max = "999999999" if @terms[base.to_sym].split("-")[1].include?(" ")
					t_base_max = @terms[base.to_sym].split("-")[1] unless @terms[base.to_sym].split("-")[1].include?(" ")
					@terms[base_min] = t_base_min
					@terms[base_max] = t_base_max
				else 
					@terms[base_min] = @terms[base_sym].to_i
					@terms[base_max] = @terms[base_sym].to_i
				end
			end
			conditions << "with(:#{base},#{@terms[base_min]..@terms[base_max]})"
		end
		conditions
	end

	def process_parcel(facetname)
		id = ""
		condition = nil

		#TODO: DO MORE ROBUST CHECKS TO SEE IF THIS IS A FIELD FACET OR AN INSTANCED FACET?
		facet = Slugger.from_slug(facetname)
		unless facet.blank?
			id = facet.facet_id
			field = facet.facet_type.underscore
			ids = Array.new
			ids << id.to_i
			unless @parcel_riders.blank?
				if @parcel_riders[field]
					for rider in @parcel_riders[field]
						newid = Slugger.id_from_slug(rider) 
						ids << newid unless newid.blank?
					end
				end
			end
			condition = "with(:#{field}_id, #{ids})" unless ids.blank?
		else

			# SPECIAL CASES. Try to infer what it is they're typing.
			if facetname.match(/\d\d\d\d/)
				unless facetname.blank?
					condition = "with(:year, '#{facetname}')" 
				end
			elsif facetname == "dealer" || facetname == "private-party"
				condition = "with(:posted_by, 'Dealer')" if facetname == "dealer"
				condition = "with(:posted_by, 'User')" if facetname == "private-party"
				if @parcel_riders["posted_by"]
					for rider in @parcel_riders["posted_by"]
						return # Instead of "RETURN ALL" just return | condition = "with(:posted_by, USER OR DEALER)"
					end
				end
			else				
				#unless facetname.blank?
				#condition = "with(:#{field}, '#{facetname}')" 
				#end
			end
		end
 		condition
	end

	def process_keywords(keywords)
		unless keywords.blank?
			dealers = Dealer.all.map(&:name)
			dealers.each { |dealer|
				name = dealer.downcase
				if name.include? keywords
					keywords = keywords.gsub(keywords," \"#{keywords}\" ")
					return keywords
				end
			}
		end
		keywords
	end

 	def build_searcher(klass,page,order,sort=:asc, perpage=12,location=nil,distance=15)
 		filters = Hash.new
 		search = Sunspot.new_search(klass)
 		kwords = @terms[:keywords]
 		kwords = URI.decode(kwords) unless kwords.blank?

 		kwords = process_keywords(kwords)

		search.build do
			unless kwords.blank?
				fulltext "'#{kwords}'" do
					fields FIELDS
				end
			end
		end

 		for condition in @parcel_conditions do
 			field = condition.match(/\w+[^with:(][^_id,\s]/)[0]
	 		search.build do
	 			filters[field] = eval condition
	 		end
	 	end

 		for condition in @term_conditions do
	 		search.build do
	 			# May need to build some filters here too!
	 			field = condition.match(/\w+[^with:(][^_id,\s]/)[0]
	 			filters[field] = eval condition unless field.blank?
 				eval condition if field.blank?
	 		end
	 	end

	 	# --------------------------------
	 	# ONLY SHOW ACTIVE AUTOS 
	 	# --------------------------------
	 	search.build do
	 		with(:status,90)
	 	end

	 	#------
	 	# Give preference to featured dealers
	 	#-----
	 	search.build do
	 		order_by(:featured_dealer, :desc)
	 	end

	 	#------
	 	# Give preference to paying customers
	 	#-----
	 	search.build do
	 		order_by(:paying_customer, :desc)
	 	end

	 	#------
	 	# Give preference to images
	 	#-----
	 	search.build do
	 		order_by(:has_images, :asc)
	 	end


	 	search.build do
		 	case order
		 	when :mileage
		 		order_by(:mileage, sort)
		 	when :price
				order_by(:price, sort)
				search.build do
					with(:price, 1..999999)
				end
			when :recent
				order_by(:created_at, sort)
			when :year
				order_by(:year, sort)
		 	else
				order_by(:price, :desc)
		 	end
		end

		unless location.blank?
		 	search.build do
		 		order_by_geodist(:location, location[0], location[1])
		 	end
	 	end

		# Include Associations	
		search.build do
			data_accessor_for(Auto).include=[:city, :body_type, :make, :model, :purchase_type, :advertiser]
		end

		unless location.blank?
			distance = 15 if distance.blank?
			search.build do
				with(:location).in_radius(location[0], location[1], distance)
			end
		end

	 	# Finishers
	 	search.build do
			facet :make_id
			facet :make_id, name: 'all_make_id', exclude: filters['make']

		    facet :model_id
		    facet :model_id, name: "all_model_id", exclude: filters["model"]
		      
		    facet :body_type_id
		    facet :body_type_id, name: "all_body_type_id", exclude: filters["body_type"]

		    facet :purchase_type_id
		    facet :purchase_type_id, name: "all_purchase_type_id", exclude: filters["purchase_type"]

		    facet :posted_by
		    facet :posted_by, name: "all_posted_by", exclude: filters["posted_by"] #TODO: THIS IS WEIRD BUT NECESSARY

		    facet :metro_id
		    facet :metro_id, name: "all_metro_id", exclude: filters["metro"]

		    facet :dealer_id
		    facet :dealer_id, name: "all_dealer_id", exclude: filters['dealer'] if filters['dealer']
      	paginate page: page, per_page: perpage
	 	end

	 	search
 	end

 	# Page and Order are here for backwards compatibility
 	def self.search(url, page = 1, order = :score, perpage = 12)
 		logger = Rails.logger
 		terms = Slugger.get_terms(url)

 		page = terms["page"].first.to_i unless terms["page"].blank?
 		order = terms["order"].first.to_sym unless terms["order"].blank?
 		sort = terms["sort"].first.to_sym unless terms["sort"].blank?
 		perpage = terms["perpage"].first.to_i unless terms["perpage"].blank?
 		zip = terms["zip"].first unless terms["zip"].blank?
 		distance = terms["distance"].first unless terms["distance"].blank?

 		location = []

 		if zip.present?
	    unless zip == "52402"
	    	logger.warn "----------geo: GET READY---------"
	      location = Rails.cache.fetch("zip_#{zip}", :expires_in => 5.days) do
	      	logger.info "----------geo: CACHE TIME---------"
	        geocoder = GeoAuto.new(zip)
	        geocoder.geocode
	        location[0] = geocoder.lat
	        location[1] = geocoder.lng
	        location
	      end
	      logger.info "----------geo: RETURNED #{location} for #{zip}---------"
	    else
		    location[0] = 42.0166364 
		    location[1] = -91.6663523 
	    end
 		end

 		slugger = self.new

 		@conditions = slugger.deslug(url)
 		searcher = slugger.build_searcher(Auto,page,order,sort,perpage,location,distance)

 		search = searcher.execute
 		search
 	end

 	# Utility
 	def self.get_terms(url)
 		h = Hash.new
 		nurl = ""
 		nurl = url.split("?")[1] unless url.split("?")[1].blank?
 		h = CGI::parse(nurl)
 		h
 	end

 	def self.hashify_params(params)
 		h = Hash.new
 		for f in Facets.facets
 			facet = params[f.to_sym]
 			h[f.to_sym] = facet unless facet.blank?
 		end
 		for t in Facets.terms
 			term = params[t.to_sym]
 			term_min = params["#{t}_min".to_sym]
 			term_max = params["#{t}_max".to_sym]
 			if term.is_a? Integer
	 			h[t.to_sym] = term unless term.blank? 
	 			h["#{t}_min".to_sym] = term_min unless term.blank?
	 			h["#{t}_max".to_sym] = term_max unless term.blank?
	 		else
	 			h[t.to_sym] = params[t.to_sym] unless term.blank?
	 		end
 		end
 		h
 	end

 	def self.deslug_facet(url,facet)
 		slug = nil
 		Slug.send(facet.underscore).each do |s|
 			slug = s.slug if url.include? s.slug
 		end
 		unless slug.blank?
 			slugs = Slug.where("slug like ? and facet_type = ?","%#{slug}%",facet)
 		end
 		if slugs && slugs.count > 1
 			tslug = nil
 			tslug_length = 0
 			slugs.each do |s|
 				len = s.slug.length
 				if len > tslug_length
	 				if url.include? s.slug
						tslug = s.slug 
 						tslug_length = len
	 				end
	 			end
 			end
 			slug = tslug unless tslug.blank?
 		end
 		return slug
	end

 	def self.from_slug(s,klass=nil)
 		unless s.blank?
	    s = s.downcase.parameterize
	    slug = Slug.where(slug:s).first
	    if slug.blank?
	    	s = s.dasherize
	    	slug = Slug.where(slug:s).first
			end
		end
    return slug unless slug.blank?
    return nil if slug.blank?
 	end

 	def self.id_from_slug(s)
	    slug = from_slug(s)
	    return slug.facet_id unless slug.blank?
	    return nil if slug.blank?
 	end

 	def self.klass_from_slug(s)
	    slug = from_slug(s)
	    return slug.facet_type unless slug.blank?
	    return nil if slug.blank?
 	end

 	# Return the actual, instantiated object and not the slug that points to it
 	def self.obj_from_slug(s)
	    slug = from_slug(s)
	    slug = slug.facet_type.camelize.constantize.send("find","#{slug.facet_id}") unless slug.blank?
	    return slug unless slug.blank?
	    return nil if slug.blank?
 	end

 	def self.ss(facet,ids)
	  search = Auto.solr_search do
	    with(facet, ids)
	  end
	  search.total
	end

 	def self.quicksearch(faceted_ids)
	  search = Auto.solr_search do
	  	with(:status,90)
	  	faceted_ids.each do |fid|
	    	with(fid[0],fid[1])
	  	end
	  end
	  search
	end

 	#def self.deslug_facet_old(url,facet)
  # slug = ""
 	#	unless facet == "Model"
	# 		Slug.send(facet.underscore).each do |s|
	# 			slug = s.slug if url.include? s.slug
	# 		end
  #		else
  #			# if we're working with a model, lets' get creative
  #			make = self.deslug_facet(url,"Make")
 	#		unless make.blank?
 	#			make = self.obj_from_slug(make)
 	#			unless make.blank?
	# 				make.models.each do |model|
	# 					slug = model.slug.slug if url.include? model.slug.slug
	# 				end
 	#			end
 	#		else
 	#			# original algorithm -- still may need to edge case it
 	#			# but we will (probably) never need it for singleton models
	#	 		Slug.send(facet.underscore).each do |s|
	#	 			slug = s.slug if url.include? s.slug
	#	 		end
 	#		end
  #
 	#	end
  #	return slug
 	#end

end

module Canon
	attr_accessor :order, :terms, :facets, :gemcutter, :url

	def self.rejectable_terms
		Facets.reject
	end

	def self.startup
		@facets = ""
		@terms = ""
		@gemcutter = Hash.new
		@order = Facets.facets
		@args = ""
	end

	# Heh.
	def self.fire(url,args=Hash.new)
		self.canonize(url,args)
	end

	def self.canonize(url,args=Hash.new)
		self.startup
		nurl = ""

		unless url.blank?
			@url = url
			@url = self.clean(url)

			# Clean out the leading /s/ and guard against nil
			self.process(@url)

			# Extract the arguments that will be terms, not facets
			@args = args
			@args = self.stringify(@args)
			@args = self.pluck_terms(@args)

			# Split up nurl with a Deslugger-type method to split out url pairs
			# Re-construct the canonized URL based on a priority system
			@gemcutter = self.extract(@facets)
			@gemcutter = self.safe_merge(@gemcutter,@args)
		end

		# Use the CanonicalOrder to reconstruct the URL
		nurl = self.order(nurl)

		# Finish the New Url before sending it off
		nurl = self.finish(nurl)

		return nurl

	end

	# in the case that we have terms that should be fully-fledged facets,
	# we should 'promote' them when the canonical facet disappears from the url
	# this method aims to do that
	def self.promote_facets(terms)
		nterms = terms
		terms = terms.split("&")
		terms.reject!(&:empty?)
		unless terms.blank?
			for t in terms
				p = t.split("=")[0]
				v = t.split("=")[1]
				unless Facets.ignored_terms.include?(p)
					slug_class = Slugger.klass_from_slug(v)
					unless slug_class.blank?
						slug_class = facetify(slug_class)
						# if slug_class is populated, it's a facet and not a term -- proceed
						if @gemcutter[slug_class].blank?
							# if we DO NOT have that term already in the gemcutter, let's put it there.
							@gemcutter[facetify(p)] = v
							nterms = self.remove_term(nterms,p,v)
						end
					else
						if p == "posted_by"
							if @gemcutter[p].blank?
								@gemcutter[facetify(p)] = v
								nterms = self.remove_term(nterms,p, v)
							end
						end
					end
				end
			end
		end
		return nterms
	end

	def self.stringify(args)
		nargs = Hash.new
		for key in args.keys do
			nargs[key.to_s] = args[key]
			args.delete(key)
		end
		return nargs
	end

	def self.pluck_terms(args)
		new_terms = ""
		for key in args.keys do
			case key
			when *Facets.allowable_terms #"year", "mileage", "price", "exclude", "outlying", "order", "sort", "keywords", "perpage", "dealership" # USE key in Facets.allowable_terms and 
				new_terms = new_terms + "&#{key.to_s}=#{args[key]}"
				args.delete(key)
			when *Facets.facets #"purchase_type", "metro", "body_type", "make", "model", "posted_by" #FACETS # use key in Facets.facets
				#Our Terms are potentially multifacets...
			when "page"
				#args.delete(key) #always remove page from facets and canonized links
			else
				#Do Nothing.
			end
		end
		@terms = @terms + new_terms
		return args
	end

	def self.clean(url)
		url = "" if url.blank?
		url = url.gsub(/\/s\//,"") unless url.blank?
		terms = false

		if url.include?("?")
			terms = true
		end

		# DO NOT facetify the keywords or dealership
		if url.include? "keywords"
			keywords = extract_term(url,"keywords")
			url = self.remove_term(url,"keywords")
		end
		if url.include? "dealership"
			dealership = extract_term(url,"dealership")
			url = self.remove_term(url,"dealership")
		end
		
		url = facetify(url)

		if terms
			unless url.include? "?"
				url = url + "?"
			end
		end

		unless keywords.blank?
			url = url + "&keywords=#{keywords}"
		end
		unless dealership.blank?
			url = url + "&dealership=#{dealership}"
		end

		return url
	end

	def self.process(url)
		
		if @url.include? "?"
			# facets are the items contained in the friendly URL bit, eg: /body_type/sedan
			# Terms are anything after the ?, eg, ?price_min=5000&price_max=10000
			facets = @url.split("?")[0]
			terms = @url.split("?")[1] 
			@facets = facets unless facets.blank?
			@facets = @url if facets.blank?
			@terms = terms unless terms.blank?
		else
			@facets = @url
		end
	end

	def self.extract(facets) 
		@facets = facets.split("/")
		@facets.reject!(&:empty?)
		@facets.each do |facet|
			unless facet.blank?
				facet = facet.split("&")[0]
				facet = facetify(facet) # Just in case.....
				slug  = Slugger.from_slug(facet)
				unless slug.blank?
					klass = slug.facet_type.underscore
					@gemcutter[klass] = facet
				else
					if facet.match(/^\d\d\d\d&/)
						@gemcutter["year"] = facet
					elsif facet.include?("dealer") || facet.include?("private_party")
						@gemcutter["posted_by"] = facet
					end
				end
			end
		end
		return @gemcutter
	end

	def self.safe_merge(gemcutter,args)
		for arg_key in args.keys
			unless gemcutter[arg_key].blank?
				value = gemcutter[arg_key]
				value = [value] unless value.kind_of? Array
				value << args[arg_key]
				gemcutter[arg_key] = value
			else
				gemcutter[arg_key] = args[arg_key]
			end
		end
		return gemcutter
	end

	def self.order(nurl)
		@terms = self.promote_facets(@terms)
		@terms = self.reject_terms(@terms)
		# Use the CanonicalOrder to reconstruct the URL

		for term in @order
			# Convert the other facet terms to TERMS and not FQ Canonized URL
			if @gemcutter[term].kind_of? Array
				first = true
				for t in @gemcutter[term]
					if first
						nurl = nurl + "/#{t}" unless @gemcutter[term].blank?
					else
						@terms = @terms + "&#{term}=#{t}"
					end
					first = false
				end
			else
				nurl = nurl + "/#{@gemcutter[term]}" unless @gemcutter[term].blank?
			end

			@gemcutter.delete(term)
		end
		return nurl
	end

	def self.finish(nurl)
		# Tack on anything we may have missed at the end
		for key in @gemcutter
			#nurl = nurl + "/#{key}/#{gemcutter[key]}" unless @gemcutter[key].blank?
			nurl = nurl + "/#{@gemcutter[key]}" unless @gemcutter[key].blank?
			#@gemcutter.delete(key)
		end
		# Last thing to do before shipping it out the door...
		nurl = nurl +"?#{@terms}" unless @terms.blank?
		nurl = "/s" + nurl

		#FACETS:
		#TODO: CHEATING
		nurl = nurl.gsub("user","private-party")

		if nurl.count("?") > 1
			pieces = nurl.split("?")
			pieces[0]+= "?"
			concat = ""
			for piece in pieces do
				concat += piece
			end
			nurl = concat
		end

		if nurl.count("?&") > 0
			nurl = nurl.gsub("?&","?")
		end

		return nurl.dasherize
	end

	def self.reject_terms(terms)
		#remove terms that we don't want to stick around on facet clicks.
		nterms = terms
		terms = terms.split("&")
		terms.reject!(&:empty?)
		unless terms.blank?
			for t in terms
				param = t.split("=")[0]
				value = t.split("=")[1]
				if self.rejectable_terms.include?(param)
					nterms = self.remove_term(nterms,param,value)
				end
			end
		end
		return nterms
	end

	def self.extract_term(url,param)
		theAnchor = ""
		newAdditionalURL = ""
    	temp = "" #AMPERSAND.
    	tempArray = url.split("?")

    	baseUrl = tempArray[0]
    	additionalUrl = tempArray[1]

    	if additionalUrl.blank?
    		#do nothing, no terms
    	else
    		terms = additionalUrl.split("&")
    		terms.each do |t|
    			termArray = t.split('=')
    			if(termArray[0] == param)
    				return termArray[1]
    			end
    		end
    	end
    	return ""
	end

	# Ported from Facets.js
	def self.remove_term(url,param,optVal=nil)
		theAnchor = ""
		newAdditionalURL = ""
    	temp = "" #AMPERSAND.
    	paramVal =  optVal || ""
    	tempArray = url.split("?")

    	baseUrl = tempArray[0]
    	additionalUrl = tempArray[1]
    	unless additionalUrl.blank?
    		tmpAnchor = additionalUrl.split("#")
    		theParams = tmpAnchor[0]
    		theAnchor = tmpAnchor[1]
    		unless(theAnchor.blank?)
    			additionalUrl = theParams
    		end
    		tempArray = additionalUrl.split("&")

    		tempArray.each do |t|
    			if(t.split('=')[0] != param)
    				pArray = t.split("=")
    				if(pArray[0]==param && pArray[1] == paramVal)
	    	            #DO NOTHING AND SCENE.
	    	        else
	    	        	newAdditionalURL += temp + t
	    	        	temp = "&"
	    	        end
	    	    end
	    	end
	    else
		  	#I dunno?
		  	unless baseUrl.blank?
		  		tmpAnchor = baseUrl.split("#") 
		  		theParams = tmpAnchor[0]
		  		theAnchor = tmpAnchor[1]
		  		unless theParams.blank?
		  			baseUrl = theParams
		  		end
		  		tempArray = baseUrl.split("&")
		  		tempArray.each do |t|
		  			#Pretty sure this next line needs an == instead of !=
		  			#Why would we only want to remove terms if the param we are looking at doesn't = param? 
		  			if(t.split('=')[0] == param)
		  				pArray = t.split("=")
		  				if(pArray[0]==param && pArray[1] == paramVal)
			                #DO NOTHING AND SCENE.
			            else
			            	newAdditionalURL += temp + t
			            	temp = "&"
			            	
			            end
			        else  # we should probably add back terms that don't match the param we were looking for
			        	newAdditionalURL += temp + t
			        	temp = "&"
			        end
			    end
			    baseUrl = ""
			end
		end

		rows_txt = ""
		if(theAnchor)
			rows_txt += "#" + theAnchor
		end
		if newAdditionalURL ==""
			return baseUrl
		end
		if baseUrl == "" && newAdditionalURL == ""
			return rows_txt
		else
			new_url ="";
			new_url = baseUrl + newAdditionalURL + rows_txt
			if new_url.include?("?")
				return new_url
			else
				new_url = baseUrl + "?" + newAdditionalURL  + rows_txt
				if new_url.split("/")[0] == "?"
					new_url = new_url.sub("?", "")
				end
				return new_url
			end
		end	
	end
end

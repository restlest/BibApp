class CitationsController < ApplicationController
  before_filter :find_authorities, :only => [:new, :edit]

  make_resourceful do
    build :index, :show, :new, :edit, :destroy
    
    publish :yaml, :xml, :json, :attributes => [
      :id, :type, :title_primary, :title_secondary, :title_tertiary,
      :year, :volume, :issue, :start_page, :end_page, :links, {
        :publication => [:id, :name]
        }, {
        :publisher => [:id, :name]
        }, {
        :name_strings => [:id, :name]
        }, {
        :people => [:id, :first_last]
        }
      ]    
    
      before :index do

        @citations = Citation.paginate(
          :all, 
          :conditions => ["citation_state_id = ?", 3],
          :order => "year desc, title_primary",
          :page => params[:page] || 1,
          :per_page => 5
        )

        @groups = Citation.find_by_sql(
          "SELECT g.*, cit.total
    	   		FROM groups g
    			JOIN (SELECT groups.id as group_id, count(distinct citations.id) as total
    					FROM citations
    					join citation_name_strings on citations.id = citation_name_strings.citation_id
    					join name_strings on citation_name_strings.name_string_id = name_strings.id
    					join pen_names on name_strings.id = pen_names.name_string_id
    					join people on pen_names.person_id = people.id
    					join memberships on people.id = memberships.person_id
    					join groups on memberships.group_id = groups.id
    					where citations.citation_state_id = 3
    					group by groups.id) as cit
    			ON g.id=cit.group_id
    			ORDER BY cit.total DESC
    			LIMIT 10"	
        )

        @people = Citation.find_by_sql(
          "SELECT p.*, cit.total
    	   		FROM people p
    			JOIN (SELECT people.id as people_id, count(distinct citations.id) as total
    					FROM citations
    					join citation_name_strings on citations.id = citation_name_strings.citation_id
    					join name_strings on citation_name_strings.name_string_id = name_strings.id
    					join pen_names on name_strings.id = pen_names.name_string_id
    					join people on pen_names.person_id = people.id
    					where citations.citation_state_id = 3
    					group by people.id) as cit
    			ON p.id=cit.people_id
    			ORDER BY cit.total DESC
    			LIMIT 10"
        )

        @publications = Citation.find_by_sql(
    	  "SELECT pub.*, cit.total
    	   		FROM publications pub
    			JOIN (SELECT publications.id as publication_id, count(distinct citations.id) as total
    					FROM citations
    					join publications on citations.publication_id = publications.id
    					where citations.citation_state_id = 3
    					group by publications.id) as cit
    			ON pub.id=cit.publication_id
    			ORDER BY cit.total DESC
    			LIMIT 10"
        )
      end
	
	#initialize variables used by 'edit.html.haml'
    before :edit do
      @name_strings = @citation.name_strings
      @publication = @citation.publication
      @keywords = @citation.keywords
    end
	
	#initialize variables used by 'new.html.haml'
	before :new do  
	  #if 'type' unspecified, default to first type in list
	  params[:type] ||= Citation.types[0]
			
	  #initialize citation subclass with any passed in citation info
	  @citation = subklass_init(params[:type], params[:citation])		
	end 
  end
  
  def create
    # @TODO: This step is dumb, we should map attrs in the SubClass::create method itself
    # If we have a Book object, we need to capture the Title as the new Publication Name
    if params[:type] == 'Book'
      params[:citation][:publication_full] = params[:citation][:title_primary]
    end
    
    # If we need to add a batch
    if params[:type] == "AddBatch"
    	
	  logger.debug("\n\n===ADDING BATCH CITATIONS===\n\n")	
      @citation = Citation.import_batch!(params[:citation][:citations])
      
      respond_to do |format|
        if @citation
          flash[:notice] = "Batch was successfully created."
          format.html {redirect_to new_citation_url}
          format.xml  {head :created, :location => citation_url(@citation)}
        else
          format.html {render :action => "new"}
          format.xml  {render :xml => @citation.errors.to_xml}
        end
      end

    else
      logger.debug("\n\n===ADDING SINGLE CITATION===\n\n")

      # Create the basic Citation SubKlass
      @citation = subklass_init(params[:type], params[:citation])
    
	  # Load other citation info available in request params
	  set_publication(@citation)
	  set_name_strings(@citation)
	  set_keywords(@citation)
    
    # @TODO: Deduplication is currently not working   
    # Initialize deduplication keys
    #Citation.set_issn_isbn_dupe_key(@citation, @citation.name_strings, @citation.publication)
    #Citation.set_title_dupe_key(citation)
    
    #@citation.save_and_set_for_index_without_callbacks
	  
    #Do any de-duping of this citation
    #Citation.deduplicate(@citation)
    
	  # @TODO: This is erroring out, since we aren't yet saving all the citation fields on the "new citation" page	  
	  #Index our citation in Solr
	  #Index.update_solr(@citation)
	
      respond_to do |format|
        if @citation.save
          flash[:notice] = "Citation was successfully created."
          format.html {redirect_to citation_url(@citation)}
          format.xml  {head :created, :location => citation_url(@citation)}
        else
          format.html {render :action => "new"}
		  format.xml  {render :xml => @citation.errors.to_xml}
        end
      end # If we are adding one
    end # If we need to add a batch
  end
  
  
  def update
    @citation = Citation.find(params[:id])
    
	# Load other citation info available in request params
	set_publication(@citation)
 	set_name_strings(@citation)
	set_keywords(@citation)
	
    respond_to do |format|
      if @citation.update_attributes(params[:citation])
        flash[:notice] = "Citation was successfully updated."
        format.html {redirect_to citation_url(@citation)}
        format.xml  {head :ok}
      else
        format.html {render :action => "edit"}
        format.xml  {render :xml => @citation.errors.to_xml}
      end
    end
  end
  
  # Load publication information from Request params
  # and set for the current citation.
  # Also sets the instance variable @publication,
  # in case any errors should occur in saving citation  
  def set_publication(citation)
	#Set Publication info for this Citation
	if params[:publication] && params[:publication][:name]
		@publication = Publication.find_or_initialize_by_name(params[:publication][:name])
		citation.publication = @publication
	end  	
  end	
  
  
  # Load name strings list from Request params
  # and set for the current citation.
  # Also sets the instance variable @author_strings,
  # in case any errors should occur in saving citation
  def set_name_strings(citation)
  	#default to empty array of author strings
	params[:name_strings] ||= []	
				
	#Set NameStrings for this Citation
	@name_strings = Array.new
	params[:name_strings].each do |add|
		@name_strings << NameString.find_or_initialize_by_name(add)
	end
	citation.name_strings = @name_strings 	
  end
  
  # Load keywords list from Request params
  # and set for the current citation.
  # Also sets the instance variable @keywords,
  # in case any errors should occur in saving citation
  def set_keywords(citation)
	#default to empty array of keywords
	params[:keywords] ||= []	
				  
	#Set Keywords for this Citation
	@keywords = Array.new
	params[:keywords].each do |add|
		@keywords << Keyword.find_or_initialize_by_name(add)
	end
	citation.keywords = @keywords 	
  end  
  	  	
  	
  #Auto-Complete for entering NameStrings in Web-based Citation entry
  #  This method provides users with a list of matching NameStrings
  #  already in BibApp.
  def auto_complete_for_name_string_name
  	name_string = params[:name_string][:name].downcase
	
	#search at beginning of name
	beginning_search = name_string + "%"
	#search at beginning of any other words in name
	word_search = "% " + name_string + "%"	
	
	name_strings = NameString.find(:all, 
			:conditions => [ "LOWER(name) LIKE ? OR LOWER(name) LIKE ?", beginning_search, word_search ], 
			:order => 'name ASC',
			:limit => 8)
		  
	render :partial => 'autocomplete_list', :locals => {:objects => name_strings}
  end    
  
  #Auto-Complete for entering Keywords in Web-based Citation entry
  #  This method provides users with a list of matching Keywords
  #  already in BibApp.
  def auto_complete_for_keyword_name
   	keyword = params[:keyword][:name].downcase
	  
	#search at beginning of word
	beginning_search = keyword + "%"
	#search at beginning of any other words
	word_search = "% " + keyword + "%"	
	  
	keywords = Keyword.find(:all, 
			  :conditions => [ "LOWER(name) LIKE ? OR LOWER(name) LIKE ?", beginning_search, word_search ], 
			  :order => 'name ASC',
			  :limit => 8)
			
	render :partial => 'autocomplete_list', :locals => {:objects => keywords}
  end    
  
  #Auto-Complete for entering Publication Titles in Web-based Citation entry
  #  This method provides users with a list of matching Publications
  #  already in BibApp.
  def auto_complete_for_publication_name
	  publication_name = params[:publication][:name].downcase
	  
	  #search at beginning of name
	  beginning_search = publication_name + "%"
	  #search at beginning of any other words in name
	  word_search = "% " + publication_name + "%"
	  
	  publications = Publication.find(:all, 
	  		  :conditions => [ "LOWER(name) LIKE ? OR LOWER(name) LIKE ?", beginning_search, word_search ], 
			  :order => 'name ASC',
			  :limit => 8)
			
	  render :partial => 'autocomplete_list', :locals => {:objects => publications}
  end    
       
  #Adds a single item value to list of items in Web-based Citation entry
  # This is used to add multiple values in form (e.g. multiple NameStrings, Keywords, etc)
  # Expects three parameters:
  # 	item_name - "Name" of type of item (e.g. "name_string", "keywords")
  #     item_value - value to add to item list
  #     clear_field - Name of form field to clear after processing is complete
  #
  # (E.g.) item_name=>"name_string", item_value=>"Donohue, Tim", clear_field=>"author_name"
  #	  Above example will add value "Donohue, Tim" to list of "author_string" values in form.
  #   Specifically, it would add a new <li> to the <ul> or <ol> with an ID of "author_string_list". 
  #   It then clears the "author_name" field (which is the textbox where the value was entered).
  #   End result example (doesn't include AJAX code created, but you get the idea):
  #   <input type="textbox" id="author_name" name="author_name" value=""/>
  #   <ul id='author_string_list'>
  #     <li id='Donohue, Timothy' class='list_item'>
  #       <input type="checkbox" id="name_string[]" name="name_string[]" value="Donohue, Tim"/> Donohue, Tim
  #     </li>
  #   </ul>
  def add_item_to_list
    @item_name = params[:item_name]
    @item_value = params[:item_value]
    @clear_field = params[:clear_field]

    #Add item value to list dynamically using Javascript
      respond_to do |format|
      format.js { render :action => :item_list }
    end
  end
	
  #Removes a single item value from list of items in Web-based Citation entry
  # This is used to remove from multiple values in form (e.g. multiple authors, keywords, etc)
  # Expects two parameters:
  #   item_name - "Name" of type of item (e.g. "name_string", "keywords")
  #   item_value - value to add to item list  
  #
  # Essentially this does the opposite of 'add_item_to_list', and removes
  # an existing item.
  def remove_item_from_list
    @item_name = params[:item_name]
    @item_value = params[:item_value]
    @remove = true

    #remove item value from list dynamically using Javascript
    respond_to do |format|
      format.js { render :action => :item_list }
    end
  end
  
  private
  
  # Initializes a new citation subclass, but doesn't create it in the database
  def subklass_init(klass_type, citation)
    klass_type.sub!(" ", "") #remove spaces
    klass_type.gsub!(/[()]/, "") #remove any parens
    klass = klass_type.constantize #change into a class
    if klass.superclass != Citation
      raise NameError.new("#{klass_type} is not a subclass of Citation") and return
    end
    citation = klass.new(citation)
  end
  
  def find_authorities
    @publication_authorities = Publication.find(:all, :conditions => ["id = authority_id"], :order => "name")
    @publisher_authorities = Publisher.find(:all, :conditions => ["id = authority_id"], :order => "name")
  end
end
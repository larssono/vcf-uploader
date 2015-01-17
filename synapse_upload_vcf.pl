#!/usr/bin/env perl

use warnings;
use strict;

use feature qw(say);
use autodie;
use Carp::Always;
use Carp qw( croak );

use Getopt::Long;
use XML::DOM;
use XML::XPath;
use XML::XPath::XMLParser;
use JSON;

#use XML::LibXML;
#use Time::Piece;

use GNOS::Upload;
use Data::Dumper;

my $milliseconds_in_an_hour = 3600000;

#############################################################################################
# DESCRIPTION                                                                               #
#############################################################################################
# 
#############################################################################################


#############
# VARIABLES #
#############

# seconds to wait for a retry
my $cooldown = 60;
# 30 retries at 60 seconds each is 30 hours
my $retries = 30;
# retries for md5sum, 4 hours
my $md5_sleep = 240;

my $parser        = new XML::DOM::Parser;
my $output_dir    = "test_output_dir";
my $xml_dir       = "xml";
my $key           = "gnostest.pem";
my $upload_url    = "";
my $test          = 0;

my ($metadata_url,$force_copy,$help);
GetOptions(
    "metadata-urls=s"  => \$metadata_url,
    "force-copy"       => \$force_copy,
    "output_dir=s"     => \$output_dir,
    "xml_dir=s"        => \$xml_dir,
    "help"             => \$help
    );

die << 'END' if $help;
Usage: synapse_upload_vcf.pl[--metadata-url url] 
                            [--force-copy] 
                            [--output_dir dir]
                            [--xml_dir]
END
;
 

say "SETTING UP OUTPUT DIRS";

$output_dir = "vcf/$output_dir";
run("mkdir -p $output_dir");
run("mkdir -p $xml_dir");
my $final_touch_file = $output_dir."upload_complete.txt";


my $link_method = ($force_copy)? 'rsync -rauv': 'ln -s';
my $pwd = `pwd`;
chomp $pwd;

# If we don't have a url, get the list by elastic search
my @metadata_urls;
unless ($metadata_url) {
    say "Getting metadata URLs by elastic search...";
    sleep 2;
    @metadata_urls = `./get_donors_by_elastic_search.pl`;
    chomp @metadata_urls;
}
else {
    @metadata_urls = ($metadata_url);
}


my %variant_workflow_version;
for my $url (@metadata_urls) {
    say "metadata URL=$url";
    my $metad = download_metadata($url);

    # we will only grab the result for the most recent variant workflow


    my $json  = generate_output_json($metad);
    my ($analysis_id) = $url =~ m!/([^/]+)$!;
#    open JFILE, ">$output_dir/$analysis_id.json";
#    print JFILE $json;
#    close JFILE;
    say "JSON saved as $output_dir/$analysis_id.json";
}


###############
# SUBROUTINES #
###############

# "used_urls": ["https://gtrepo-dkfz.annailabs.com/cghub/data/analysis/download/.../comma_list_of_aligned_bam_files",
#                "ftp://ftp.1000genomes.ebi.ac.uk/vol1/ftp/technical/reference/phase2_reference_assembly_sequence/hs37d5.fa.gz/.../or_other_correct_url"],
# "executed_urls":  ["https://github.com/SeqWare/public-workflows/tree/vcf-1.1.0/workflow-DKFZ-bundle",
#                    "https://s3.amazonaws.com/oicr.workflow.bundles/released-bundles/Workflow_Bundle_BWA_2.6.0_SeqWare_1.0.15.zip/.../Point/to_Correct/URL"],

# This method gets the information about the BWA alignment outputs/VCF inputs
sub get_sample_data {
    my $metad = shift;
    my $json  = shift;
    my $anno  = $json->{annotations};
    my ($input_json_string) = keys %{$metad->{variant_pipeline_input_info}};
    my $input_data = decode_json $input_json_string;

    my ($inputs)     = values %$input_data; 

    my ($tumor_sid, $normal_sid, @urls, $tumor_aid, $normal_aid);
    for my $specimen (@$inputs) {
	my $type = $specimen->{attributes}->{dcc_specimen_type};
	my $sample_id = $specimen->{specimen};
	my $analysis_id =  $specimen->{attributes}->{analysis_id};
	my $is_tumor = $type =~ /tumou?r|xenograft|cell line/i;
	if ($is_tumor) {
	    $tumor_sid = $tumor_sid ? "$tumor_sid,$sample_id" : $sample_id;
	    $tumor_aid = $tumor_aid ? "$tumor_aid,$analysis_id" : $analysis_id;
	}
	else {
	    $normal_sid = $normal_sid ? "$normal_sid,$sample_id" : $sample_id;
	    $normal_aid = $normal_aid ? "$normal_aid,$analysis_id" : $analysis_id;
	}
	
	push @urls, $specimen->{attributes}->{analysis_url};
    }

    $anno->{sample_id_normal}  = $normal_sid;
    $anno->{aalysis_id_normal} = $normal_aid;
    $anno->{sample_id_tumor}   = $tumor_sid;
    $anno->{analysis_id_tumor} = $tumor_aid;
    $json->{used_urls} = \@urls;
}


# We will neeed to grab the files from GNOS assuming synpase upload is
# not concurrent with GNOS upload
sub download_vcf_files {
    my $metad = shift;
    my $url = shift;
    my @data = @_;
    say "This is where I will be downloading files from GNOS";
    for my $file (@data) {
	my ($name,$checksum) = @$file;
	my $file_name = "$output_dir/$name";
	my $download_url = $metad->{$url}->{download_url};
	# and add the logic to download
    }
}

sub get_files {
    my $metad = shift;
    my $url   = shift;
    my $file_data = $metad->{$url}->{file};
    my @file_data = map {[$_->{filename},$_->{checksum}]} @$file_data;
    download_vcf_files($metad,$url,@file_data);
    return @file_data;
}

sub get_file_names {
    my $metad = shift;
    my $url   = shift;
    my @data  = get_files($metad,$url);
    my @names = map {$_->[0]} @data;
    return [map{"$output_dir/$_"} @names];
}

sub generate_output_json {
    my ($metad) = @_;
    my $data = {};

    foreach my $url ( keys %{$metad} ) {
	$data->{files} = get_file_names($metad,$url);

	my $atts = $metad->{$url}->{analysis_attr};
	my $anno = $data->{annotations} = {};
	
	# top-level annotations
        $anno->{center_name}     = $metad->{$url}->{center_name};
        $anno->{reference_build} =  $metad->{$url}->{reference_build};

	# get original sample information
	get_sample_data($atts,$data);

	# from the attributes hash
	($anno->{donor_id})                   = keys %{$atts->{submitter_donor_id}};
	($anno->{study})                      = keys %{$atts->{STUDY}};
	($anno->{alignment_workflow_name})    = keys %{$atts->{alignment_workflow_name}};
	($anno->{alignment_workflow_version}) = keys %{$atts->{alignment_workflow_version }};
	($anno->{sequence_source})            = keys %{$atts->{sequence_source}};
	($anno->{workflow_url})               = keys %{$atts->{variant_workflow_bundle_url}};
	($anno->{workflow_src_url})           = keys %{$atts->{variant_workflow_source_url}};
	($anno->{project_code})               = keys %{$atts->{dcc_project_code}};
	($anno->{workflow_version})           = keys %{$atts->{variant_workflow_version}};
	($anno->{workflow_name})              = keys %{$atts->{variant_workflow_name}};
        $anno->{original_analysis_id}         = join(',',sort keys %{$atts->{original_analysis_id}});

	# harder to get attributes
	$anno->{call_type} = (grep {/\.somatic\./} @{$data->{files}}) ? 'somatic' : 'germline';

	my $wiki = $data->{wiki_content} = {};
	$wiki->{title}                = $metad->{$url}->{title};
	$wiki->{description}          = $metad->{$url}->{description};

	my $exe_urls = $data->{executed_urls} = [];
	push @$exe_urls, keys %{$atts->{variant_workflow_bundle_url}};
	push @$exe_urls, keys %{$atts->{alignment_workflow_bundle_url}};
    }


    my $json = JSON->new->pretty->encode( $data);
    say $json;
    return $json;
}

sub download_metadata {
    my $url = shift;
    my $metad = {};

    my ($id) = $url =~ m!/([^/]+)$!;
    my $xml_path = download_url( $url, "$xml_dir/data_$id.xml" );
    $metad->{$url} = parse_metadata($xml_path);

    return $metad;
}

sub parse_metadata {
    my ($xml_path) = @_;
    my $doc        = $parser->parsefile($xml_path);
    my $m          = {};

    $m->{'analysis_id'}  = getVal( $doc, 'analysis_id' );
    $m->{'center_name'}  = getVal( $doc, 'center_name' );
    $m->{'title'}        = getVal( $doc, 'TITLE');
    $m->{'description'}  = getVal( $doc, 'DESCRIPTION');
    $m->{'platform'}     = getVal( $doc, 'platform');
    $m->{'download_url'} = getVal( $doc, 'analysis_data_uri');
    $m->{'reference_build'} = getTagAttVal( $doc, 'STANDARD', 'short_name' );
    $m->{'analysis_center'} = getTagAttVal( $doc, 'ANALYSIS', 'analysis_center' );

    push @{ $m->{'file'} },
      getValsMulti( $doc, 'FILE', "checksum,filename,filetype" );

    $m->{'analysis_attr'} = getAttrs($doc);
    return ($m);
}

sub getBlock {
    my ( $xml_file, $xpath ) = @_;

    my $block = "";
    ## use XPath parser instead of using REGEX to extract desired XML fragment, to fix issue: https://jira.oicr.on.ca/browse/PANCANCER-42
    my $xp = XML::XPath->new( filename => $xml_file )
      or die "Can't open file $xml_file\n";

    my $nodeset = $xp->find($xpath);
    foreach my $node ( $nodeset->get_nodelist ) {
        $block .= XML::XPath::XMLParser::as_string($node) . "\n";
    }

    return $block;
}

sub download_url {
    my ( $url, $path ) = @_;

    my $response = run("wget -q -O $path $url");
    if ($response) {
        $ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;
        $response = run("lwp-download $url $path");
        if ($response) {
            say "ERROR DOWNLOADING: $url";
            exit 1;
        }
    }
    return $path;
}

sub getVal {
    my ( $node, $key ) = @_;

    if ( $node ) {
        if ( defined( $node->getElementsByTagName($key) ) ) {
            if ( defined( $node->getElementsByTagName($key)->item(0) ) ) {
                if (
                    defined(
                        $node->getElementsByTagName($key)->item(0)
                          ->getFirstChild
                    )
                  )
                {
                    if (
                        defined(
                            $node->getElementsByTagName($key)->item(0)
                              ->getFirstChild->getNodeValue
                        )
                      )
                    {
                        return ( $node->getElementsByTagName($key)->item(0)
                              ->getFirstChild->getNodeValue );
                    }
                }
            }
        }
    }
    return (undef);
}

sub getAttrs {
    my ($node) = @_;

    my $r     = {};
    my $nodes = $node->getElementsByTagName('ANALYSIS_ATTRIBUTE');
    for ( my $i = 0 ; $i < $nodes->getLength ; $i++ ) {
        my $anode = $nodes->item($i);
        my $tag   = getVal( $anode, 'TAG' );
        my $val   = getVal( $anode, 'VALUE' );
        $r->{$tag}{$val} = 1;
    }

    return $r;
}

sub getTagAttVal {
    my $doc = shift;
    my $tag = shift;
    my $att = shift;
    my $nodes = $doc->getElementsByTagName($tag);
    my $n = $nodes->getLength;

    for (my $i = 0; $i < $n; $i++)
    {
	my $node = $nodes->item($i);
	my $val = $node->getAttributeNode($att);
	return $val->getValue;
    }
}

sub getValsWorking {
    my ( $node, $key, $tag ) = @_;

    my @result;
    my $nodes = $node->getElementsByTagName($key);
    for ( my $i = 0 ; $i < $nodes->getLength ; $i++ ) {
        my $anode = $nodes->item($i);
        my $tag   = $anode->getAttribute($tag);
        push @result, $tag;
    }

    return @result;
}

sub getValsMulti {
    my ( $node, $key, $tags_str ) = @_;
    my @result;
    my @tags = split /,/, $tags_str;
    my $nodes = $node->getElementsByTagName($key);
    for ( my $i = 0 ; $i < $nodes->getLength ; $i++ ) {
        my $data = {};
        foreach my $tag (@tags) {
            my $anode = $nodes->item($i);
            my $value = $anode->getAttribute($tag);
            if ( defined($value) && $value ne '' ) { $data->{$tag} = $value; }
        }
        push @result, $data;
    }
    return (@result);
}

sub run {
    my ( $cmd, $do_die ) = @_;

    say "CMD: $cmd";
    my $result = system($cmd);
    if ( $do_die && $result ) {
        croak "ERROR: CMD '$cmd' returned non-zero status";
    }

    return ($result);
}

0;

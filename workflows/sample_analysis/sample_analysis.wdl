version 1.0

# Run for each sample in the cohort. Aligns reads from each movie to the reference genome, then calls and phases small and structural variants.

import "../humanwgs_structs.wdl"
import "../wdl-common/wdl/tasks/pbsv_discover.wdl" as PbsvDiscover
import "../wdl-common/wdl/workflows/deepvariant/deepvariant.wdl" as DeepVariant
import "../wdl-common/wdl/tasks/bcftools_stats.wdl" as BcftoolsStats
import "../wdl-common/wdl/tasks/mosdepth.wdl" as Mosdepth
import "../wdl-common/wdl/tasks/pbsv_call.wdl" as PbsvCall
import "../wdl-common/wdl/tasks/zip_index_vcf.wdl" as ZipIndexVcf
import "../wdl-common/wdl/workflows/phase_vcf/phase_vcf.wdl" as PhaseVcf
import "../wdl-common/wdl/tasks/whatshap_haplotag.wdl" as WhatshapHaplotag

workflow sample_analysis {
	input {
		Sample sample

		ReferenceData reference

		String deepvariant_version
		DeepVariantModel? deepvariant_model

		RuntimeAttributes default_runtime_attributes
	}

	scatter (movie_bam in sample.movie_bams) {
		call pbmm2_align {
			input:
				sample_id = sample.sample_id,
				bam = movie_bam,
				reference = reference.fasta.data,
				reference_index = reference.fasta.data_index,
				reference_name = reference.name,
				runtime_attributes = default_runtime_attributes
		}

		call PbsvDiscover.pbsv_discover {
			input:
				aligned_bam = pbmm2_align.aligned_bam,
				aligned_bam_index = pbmm2_align.aligned_bam_index,
				reference_tandem_repeat_bed = reference.tandem_repeat_bed,
				runtime_attributes = default_runtime_attributes
		}

		IndexData aligned_bam = {
			"data": pbmm2_align.aligned_bam,
			"data_index": pbmm2_align.aligned_bam_index
		}
	}

	call DeepVariant.deepvariant {
		input:
			sample_id = sample.sample_id,
			aligned_bams = aligned_bam,
			reference_fasta = reference.fasta,
			reference_name = reference.name,
			deepvariant_version = deepvariant_version,
			deepvariant_model = deepvariant_model,
			default_runtime_attributes = default_runtime_attributes
	}

	call BcftoolsStats.bcftools_stats {
		input:
			vcf = deepvariant.vcf.data,
			params = "--apply-filters PASS --samples ~{sample.sample_id}",
			reference = reference.fasta.data,
			runtime_attributes = default_runtime_attributes
	}

	call bcftools_roh {
		input:
			vcf = deepvariant.vcf.data,
			runtime_attributes = default_runtime_attributes
	}

	call PbsvCall.pbsv_call {
		input:
			sample_id = sample.sample_id,
			svsigs = pbsv_discover.svsig,
			reference = reference.fasta.data,
			reference_index = reference.fasta.data_index,
			reference_name = reference.name,
			runtime_attributes = default_runtime_attributes
	}

	call ZipIndexVcf.zip_index_vcf {
		input:
			vcf = pbsv_call.pbsv_vcf,
			runtime_attributes = default_runtime_attributes
	}

	call PhaseVcf.phase_vcf {
		input:
			vcf = deepvariant.vcf,
			aligned_bams = aligned_bam,
			reference_fasta = reference.fasta,
			reference_chromosome_lengths = reference.chromosome_lengths,
			regions = reference.chromosomes,
			default_runtime_attributes = default_runtime_attributes
	}

	scatter (bam_object in aligned_bam) {
		if (length(aligned_bam) == 1) {
			String output_bam_name = "~{sample.sample_id}.~{reference.name}.haplotagged.bam"
		}

		call WhatshapHaplotag.whatshap_haplotag {
			input:
				phased_vcf = phase_vcf.phased_vcf.data,
				phased_vcf_index = phase_vcf.phased_vcf.data_index,
				aligned_bam = bam_object.data,
				aligned_bam_index = bam_object.data_index,
				reference = reference.fasta.data,
				reference_index = reference.fasta.data_index,
				output_bam_name = output_bam_name,
				runtime_attributes = default_runtime_attributes
		}
	}

	if (length(whatshap_haplotag.haplotagged_bam) > 1) {
		call merge_bams {
			input:
				bams = whatshap_haplotag.haplotagged_bam,
				output_bam_name = "~{sample.sample_id}.~{reference.name}.haplotagged.bam",
				runtime_attributes = default_runtime_attributes
		}
	}

	File haplotagged_bam = select_first([merge_bams.merged_bam, whatshap_haplotag.haplotagged_bam[0]])
	File haplotagged_bam_index = select_first([merge_bams.merged_bam_index, whatshap_haplotag.haplotagged_bam_index[0]])

	call Mosdepth.mosdepth {
		input:
			aligned_bam = haplotagged_bam,
			aligned_bam_index = haplotagged_bam_index,
			runtime_attributes = default_runtime_attributes
	}

	call trgt {
		input:
			sample_id = sample.sample_id,
			sex = sample.sex,
			bam = haplotagged_bam,
			bam_index = haplotagged_bam_index,
			reference = reference.fasta.data,
			reference_index = reference.fasta.data_index,
			tandem_repeat_bed = reference.trgt_tandem_repeat_bed,
			output_prefix = "~{sample.sample_id}.~{reference.name}",
			runtime_attributes = default_runtime_attributes
	}

	call cpg_pileup {
		input:
			bam = haplotagged_bam,
			bam_index = haplotagged_bam_index,
			output_prefix = "~{sample.sample_id}.~{reference.name}",
			reference = reference.fasta.data,
			reference_index = reference.fasta.data_index,
			runtime_attributes = default_runtime_attributes
	}

	call paraphase {
		input:
			sample_id = sample.sample_id,
			bam = haplotagged_bam,
			bam_index = haplotagged_bam_index,
			reference = reference.fasta.data,
			reference_index = reference.fasta.data_index,
			out_directory = "~{sample.sample_id}.paraphase",
			runtime_attributes = default_runtime_attributes
	}

	call hificnv {
		input:
			sample_id = sample.sample_id,
			sex = sample.sex,
			bam = haplotagged_bam,
			bam_index = haplotagged_bam_index,
			phased_vcf = phase_vcf.phased_vcf.data,
			phased_vcf_index = phase_vcf.phased_vcf.data_index,
			reference = reference.fasta.data,
			reference_index = reference.fasta.data_index,
			exclude_bed = reference.hificnv_exclude_bed.data,
			exclude_bed_index = reference.hificnv_exclude_bed.data_index,
			expected_bed_male = reference.hificnv_expected_bed_male,
			expected_bed_female = reference.hificnv_expected_bed_female,
			output_prefix = "hificnv",
			runtime_attributes = default_runtime_attributes
	}

	output {
		Array[File] bam_stats = pbmm2_align.bam_stats
		Array[File] read_length_summary = pbmm2_align.read_length_summary
		Array[File] read_quality_summary = pbmm2_align.read_quality_summary
		Array[IndexData] aligned_bams = aligned_bam
		Array[File] svsigs = pbsv_discover.svsig

		IndexData small_variant_vcf = deepvariant.vcf
		IndexData small_variant_gvcf = deepvariant.gvcf
		File small_variant_vcf_stats = bcftools_stats.stats
		File small_variant_roh_bed = bcftools_roh.roh_bed

		IndexData sv_vcf = {"data": zip_index_vcf.zipped_vcf, "data_index": zip_index_vcf.zipped_vcf_index}

		IndexData phased_small_variant_vcf = phase_vcf.phased_vcf
		File whatshap_stats_gtf = phase_vcf.whatshap_stats_gtf
		File whatshap_stats_tsv = phase_vcf.whatshap_stats_tsv
		File whatshap_stats_blocklist = phase_vcf.whatshap_stats_blocklist
		IndexData merged_haplotagged_bam = {"data": haplotagged_bam, "data_index": haplotagged_bam_index}
		File haplotagged_bam_mosdepth_summary = mosdepth.summary
		File haplotagged_bam_mosdepth_region_bed = mosdepth.region_bed

		IndexData trgt_spanning_reads = {"data": trgt.spanning_reads, "data_index": trgt.spanning_reads_index}
		IndexData trgt_repeat_vcf = {"data": trgt.repeat_vcf, "data_index": trgt.repeat_vcf_index}
		File trgt_dropouts = trgt.trgt_dropouts

		Array[File] cpg_pileup_beds = cpg_pileup.pileup_beds
		Array[File] cpg_pileup_bigwigs = cpg_pileup.pileup_bigwigs

		File paraphase_output_json = paraphase.output_json
		IndexData paraphase_realigned_bam = {"data": paraphase.realigned_bam, "data_index": paraphase.realigned_bam_index}
		Array[File] paraphase_vcfs = paraphase.paraphase_vcfs
    
		IndexData hificnv_vcf = {"data": hificnv.cnv_vcf, "data_index": hificnv.cnv_vcf_index}
		File hificnv_copynum_bedgraph = hificnv.copynum_bedgraph
		File hificnv_depth_bw = hificnv.depth_bw
		File hificnv_maf_bw = hificnv.maf_bw
	}

	parameter_meta {
		sample: {help: "Sample information and associated data files"}
		reference: {help: "Reference genome data"}
		deepvariant_version: {help: "Version of deepvariant to use"}
		deepvariant_model: {help: "Optional deepvariant model file to use"}
		default_runtime_attributes: {help: "Default RuntimeAttributes; spot if preemptible was set to true, otherwise on_demand"}
	}
}

task pbmm2_align {
	input {
		String sample_id
		File bam

		File reference
		File reference_index
		String reference_name

		RuntimeAttributes runtime_attributes
	}

	String movie = basename(bam, ".bam")

	Int threads = 24
	Int mem_gb = ceil(threads * 4)
	Int disk_size = ceil((size(bam, "GB") + size(reference, "GB")) * 4 + 20)

	command <<<
		set -euo pipefail

		pbmm2 --version

		pbmm2 align \
			--num-threads ~{threads} \
			--sort-memory 4G \
			--preset HIFI \
			--sample ~{sample_id} \
			--log-level INFO \
			--sort \
			--unmapped \
			~{reference} \
			~{bam} \
			~{sample_id}.~{movie}.~{reference_name}.aligned.bam

		# movie stats
		extract_read_length_and_qual.py \
			~{bam} \
		> ~{sample_id}.~{movie}.read_length_and_quality.tsv

		awk '{{ b=int($2/1000); b=(b>39?39:b); print 1000*b "\t" $2; }}' \
			~{sample_id}.~{movie}.read_length_and_quality.tsv \
			| sort -k1,1g \
			| datamash -g 1 count 1 sum 2 \
			| awk 'BEGIN {{ for(i=0;i<=39;i++) {{ print 1000*i"\t0\t0"; }} }} {{ print; }}' \
			| sort -k1,1g \
			| datamash -g 1 sum 2 sum 3 \
		> ~{sample_id}.~{movie}.read_length_summary.tsv

		awk '{{ print ($3>50?50:$3) "\t" $2; }}' \
				~{sample_id}.~{movie}.read_length_and_quality.tsv \
			| sort -k1,1g \
			| datamash -g 1 count 1 sum 2 \
			| awk 'BEGIN {{ for(i=0;i<=60;i++) {{ print i"\t0\t0"; }} }} {{ print; }}' \
			| sort -k1,1g \
			| datamash -g 1 sum 2 sum 3 \
		> ~{sample_id}.~{movie}.read_quality_summary.tsv
	>>>

	output {
		File aligned_bam = "~{sample_id}.~{movie}.~{reference_name}.aligned.bam"
		File aligned_bam_index = "~{sample_id}.~{movie}.~{reference_name}.aligned.bam.bai"
		File bam_stats = "~{sample_id}.~{movie}.read_length_and_quality.tsv"
		File read_length_summary = "~{sample_id}.~{movie}.read_length_summary.tsv"
		File read_quality_summary = "~{sample_id}.~{movie}.read_quality_summary.tsv"
	}

	runtime {
		docker: "~{runtime_attributes.container_registry}/pbmm2@sha256:4ead08f03854bf9d21227921fd957453e226245d5459fde3c87c91d4bdfd7f3c"
		cpu: threads
		memory: mem_gb + " GB"
		disk: disk_size + " GB"
		disks: "local-disk " + disk_size + " HDD"
		preemptible: runtime_attributes.preemptible_tries
		maxRetries: runtime_attributes.max_retries
		awsBatchRetryAttempts: runtime_attributes.max_retries
		queueArn: runtime_attributes.queue_arn
		zones: runtime_attributes.zones
	}
}

task bcftools_roh {
	input {
		File vcf

		RuntimeAttributes runtime_attributes
	}

	String vcf_basename = basename(vcf, ".vcf.gz")
	Int threads = 2
	Int disk_size = ceil(size(vcf, "GB") * 2 + 20)

	command <<<
		set -euo pipefail

		bcftools --version

		echo -e "#chr\\tstart\\tend\\tqual" > ~{vcf_basename}.roh.bed
		bcftools roh \
			--threads ~{threads - 1} \
			--AF-dflt 0.4 \
			~{vcf} \
		| awk -v OFS='\t' '$1=="RG" {{ print $3, $4, $5, $8 }}' \
		>> ~{vcf_basename}.roh.bed
	>>>

	output {
		File roh_bed = "~{vcf_basename}.roh.bed"
	}

	runtime {
		docker: "~{runtime_attributes.container_registry}/bcftools@sha256:36d91d5710397b6d836ff87dd2a924cd02fdf2ea73607f303a8544fbac2e691f"
		cpu: threads
		memory: "4 GB"
		disk: disk_size + " GB"
		disks: "local-disk " + disk_size + " HDD"
		preemptible: runtime_attributes.preemptible_tries
		maxRetries: runtime_attributes.max_retries
		awsBatchRetryAttempts: runtime_attributes.max_retries
		queueArn: runtime_attributes.queue_arn
		zones: runtime_attributes.zones
	}
}

task merge_bams {
	input {
		Array[File] bams

		String output_bam_name

		RuntimeAttributes runtime_attributes
	}

	Int threads = 8
	Int disk_size = ceil(size(bams[0], "GB") * length(bams) * 2 + 20)

	command <<<
		set -euo pipefail

		samtools --version

		samtools merge \
			-@ ~{threads - 1} \
			-o ~{output_bam_name} \
			~{sep=' ' bams}

		samtools index ~{output_bam_name}
	>>>

	output {
		File merged_bam = "~{output_bam_name}"
		File merged_bam_index = "~{output_bam_name}.bai"
	}

	runtime {
		docker: "~{runtime_attributes.container_registry}/samtools@sha256:83ca955c4a83f72f2cc229f41450eea00e73333686f3ed76f9f4984a985c85bb"
		cpu: threads
		memory: "4 GB"
		disk: disk_size + " GB"
		disks: "local-disk " + disk_size + " LOCAL"
		preemptible: runtime_attributes.preemptible_tries
		maxRetries: runtime_attributes.max_retries
		awsBatchRetryAttempts: runtime_attributes.max_retries
		queueArn: runtime_attributes.queue_arn
		zones: runtime_attributes.zones
	}
}

task trgt {
	input {
		String sample_id
		String? sex

		File bam
		File bam_index

		File reference
		File reference_index
		File tandem_repeat_bed

		String output_prefix

		RuntimeAttributes runtime_attributes
	}

	Boolean sex_defined = defined(sex)
	String karyotype = if select_first([sex, "FEMALE"]) == "MALE" then "XY" else "XX"
	String bam_basename = basename(bam, ".bam")
	Int threads = 4
	Int disk_size = ceil((size(bam, "GB") + size(reference, "GB")) * 2 + 20)

	command <<<
		set -euo pipefail

		echo ~{if sex_defined then "" else "Sex is not defined for ~{sample_id}.  Defaulting to karyotype XX for TRGT."}

		trgt --version

		trgt \
			--threads ~{threads} \
			--karyotype ~{karyotype} \
			--genome ~{reference} \
			--repeats ~{tandem_repeat_bed} \
			--reads ~{bam} \
			--output-prefix ~{bam_basename}.trgt

		bcftools --version

		bcftools sort \
			--output-type z \
			--output ~{bam_basename}.trgt.sorted.vcf.gz \
			~{bam_basename}.trgt.vcf.gz

		bcftools index \
			--threads ~{threads - 1} \
			--tbi \
			~{bam_basename}.trgt.sorted.vcf.gz
		
		samtools --version

		samtools sort \
			-@ ~{threads - 1} \
			-o ~{bam_basename}.trgt.spanning.sorted.bam \
			~{bam_basename}.trgt.spanning.bam

		samtools index \
			-@ ~{threads - 1} \
			~{bam_basename}.trgt.spanning.sorted.bam

		# Get coverage dropouts
		check_trgt_coverage.py \
			~{tandem_repeat_bed} \
			~{bam} \
		> ~{output_prefix}.trgt.dropouts.txt
	>>>

	output {
		File spanning_reads = "~{bam_basename}.trgt.spanning.sorted.bam"
		File spanning_reads_index = "~{bam_basename}.trgt.spanning.sorted.bam.bai"
		File repeat_vcf = "~{bam_basename}.trgt.sorted.vcf.gz"
		File repeat_vcf_index = "~{bam_basename}.trgt.sorted.vcf.gz.tbi"
		File trgt_dropouts = "~{output_prefix}.trgt.dropouts.txt"
	}

	runtime {
		docker: "~{runtime_attributes.container_registry}/trgt@sha256:4eb7cced5e7a3f52815aeca456d95148682ad4c29d7c5e382e11d7c629ec04d0"
		cpu: threads
		memory: "4 GB"
		disk: disk_size + " GB"
		disks: "local-disk " + disk_size + " HDD"
		preemptible: runtime_attributes.preemptible_tries
		maxRetries: runtime_attributes.max_retries
		awsBatchRetryAttempts: runtime_attributes.max_retries
		queueArn: runtime_attributes.queue_arn
		zones: runtime_attributes.zones
	}
}

task cpg_pileup {
	input {
		File bam
		File bam_index

		String output_prefix

		File reference
		File reference_index

		RuntimeAttributes runtime_attributes
	}

	Int threads = 12
	# Uses ~4 GB memory / thread
	Int mem_gb = threads * 4
	Int disk_size = ceil((size(bam, "GB") + size(reference, "GB")) * 2 + 20)

	command <<<
		set -euo pipefail

		aligned_bam_to_cpg_scores --version

		aligned_bam_to_cpg_scores \
			--threads ~{threads} \
			--bam ~{bam} \
			--ref ~{reference} \
			--output-prefix ~{output_prefix} \
			--min-mapq 1 \
			--min-coverage 10 \
			--model "$PILEUP_MODEL_DIR"/pileup_calling_model.v1.tflite
	>>>

	output {
		Array[File] pileup_beds = glob("~{output_prefix}.*.bed")
		Array[File] pileup_bigwigs = glob("~{output_prefix}.*.bw")
	}

	runtime {
		docker: "~{runtime_attributes.container_registry}/pb-cpg-tools@sha256:f4c3e6a518d49bcdbf306c671d992604532e21e17cc7777f2f07763db642dbb8"
		cpu: threads
		memory: mem_gb + " GB"
		disk: disk_size + " GB"
		disks: "local-disk " + disk_size + " HDD"
		preemptible: runtime_attributes.preemptible_tries
		maxRetries: runtime_attributes.max_retries
		awsBatchRetryAttempts: runtime_attributes.max_retries
		queueArn: runtime_attributes.queue_arn
		zones: runtime_attributes.zones
	}
}

task paraphase {
	input {
		File bam
		File bam_index

		File reference
		File reference_index

		String sample_id
		String out_directory

		RuntimeAttributes runtime_attributes
	}

	Int threads = 4
	Int mem_gb = 4
	Int disk_size = ceil(size(bam, "GB") + 20)

	command <<<
		set -euo pipefail

		paraphase --version

		paraphase \
			--threads ~{threads} \
			--bam ~{bam} \
			--reference ~{reference} \
			--out ~{out_directory}
	>>>

	output {
		File output_json = "~{out_directory}/~{sample_id}.json"
		File realigned_bam = "~{out_directory}/~{sample_id}_realigned_tagged.bam"
		File realigned_bam_index = "~{out_directory}/~{sample_id}_realigned_tagged.bam.bai"
		Array[File] paraphase_vcfs = glob("~{out_directory}/~{sample_id}_vcfs/*.vcf")
	}

	runtime {
		docker: "~{runtime_attributes.container_registry}/paraphase@sha256:76b77fae86e006937a76e8e43542985104ee8388dc641aa24ea38732921fca8d"
		cpu: threads
		memory: mem_gb + " GB"
		disk: disk_size + " GB"
		disks: "local-disk " + disk_size + " HDD"
		preemptible: runtime_attributes.preemptible_tries
		maxRetries: runtime_attributes.max_retries
		awsBatchRetryAttempts: runtime_attributes.max_retries
		queueArn: runtime_attributes.queue_arn
		zones: runtime_attributes.zones
	}
}

task hificnv {
	input {
		String sample_id
		String? sex

		File bam
		File bam_index

		File phased_vcf
		File phased_vcf_index

		File reference
		File reference_index

		File exclude_bed
		File exclude_bed_index

		File expected_bed_male
		File expected_bed_female

		String output_prefix

		RuntimeAttributes runtime_attributes
	}

	Boolean sex_defined = defined(sex)
	File expected_bed = if select_first([sex, "FEMALE"]) == "MALE" then expected_bed_male else expected_bed_female

	Int threads = 8
	# Uses ~2 GB memory / thread
	Int mem_gb = threads * 2
	# <1 GB for output
	Int disk_size = ceil((size(bam, "GB") + size(reference, "GB"))+ 20)

	command <<<
		set -euo pipefail

		echo ~{if sex_defined then "" else "Sex is not defined for ~{sample_id}.  Defaulting to karyotype XX for HiFiCNV."}

		hificnv --version

		hificnv \
			--threads ~{threads} \
			--bam ~{bam} \
			--ref ~{reference} \
			--maf ~{phased_vcf} \
			--exclude ~{exclude_bed} \
			--expected-cn ~{expected_bed} \
			--output-prefix ~{output_prefix}

		bcftools index --tbi ~{output_prefix}.~{sample_id}.vcf.gz
	>>>

	output {
		File cnv_vcf = "~{output_prefix}.~{sample_id}.vcf.gz"
		File cnv_vcf_index = "~{output_prefix}.~{sample_id}.vcf.gz.tbi"
		File copynum_bedgraph = "~{output_prefix}.~{sample_id}.copynum.bedgraph"
		File depth_bw = "~{output_prefix}.~{sample_id}.depth.bw"
		File maf_bw = "~{output_prefix}.~{sample_id}.maf.bw"
	}

	runtime {
		docker: "~{runtime_attributes.container_registry}/hificnv@sha256:0bd33af16b788859750ea1711d49e332b9db49cc3e2431297fb00d437d93ebe9"
		cpu: threads
		memory: mem_gb + " GB"
		disk: disk_size + " GB"
		disks: "local-disk " + disk_size + " HDD"
		preemptible: runtime_attributes.preemptible_tries
		maxRetries: runtime_attributes.max_retries
		awsBatchRetryAttempts: runtime_attributes.max_retries
		queueArn: runtime_attributes.queue_arn
		zones: runtime_attributes.zones
	}
}

package moonchart.formats.fnf;

import moonchart.backend.FormatData;
import moonchart.backend.Timing;
import moonchart.backend.Util;
import moonchart.formats.BasicFormat;
import moonchart.formats.fnf.FNFGlobal;
import moonchart.formats.fnf.FNFVSlice;
import moonchart.formats.fnf.legacy.FNFLegacy;

using StringTools;

enum abstract FNFVsDaveMetaValues(String) from String to String
{
	var VISUAL_ARTISTS;
	var CODERS;
}

class FNFVsDave extends BasicJsonFormat<FNFVsDaveFormat, FNFVsDaveMeta>
{
	public static final VS_DAVE_CHART_VERSION:String = "2.0.0";
	public static final VS_DAVE_DEFAULT_STYLE:String = "normal";
	/**
	 * The default must hit section value.
	 */
	public static var FNF_LEGACY_DEFAULT_MUSTHIT:Bool = true;

	public static inline var FNF_LEGACY_MUST_HIT_SECTION_EVENT:String = "FNF_MUST_HIT_SECTION";

	public static function __getFormat():FormatData
	{
		return {
			ID: FNF_VSDAVE,
			name: "FNF (Vs. Dave)",
			description: "The format used in Vs. Dave & Bambi Volume 1",
			extension: "json",
			hasMetaFile: TRUE,
			handler: FNFVsDave
		};
	}

	// TODO: Maybe some add some metadata for extrakey formats?
	public static inline function mustHitLane(mustHit:Bool, lane:Int8):Int8
	{
		return (mustHit ? lane : (lane + 4) % 8);
	}

	public static inline function makeMustHitSectionEvent(time:Float, mustHit:Bool):BasicEvent
	{
		return {
			time: time,
			name: FNF_LEGACY_MUST_HIT_SECTION_EVENT,
			data: {
				mustHitSection: mustHit
			}
		}
	}
	/**
	 * FNF (Legacy) handles sustains by being 1 step crochet behind their actual length.
	 * You can turn it off here if your legacy extended format doesn't have this quirk.
	 */
	public var offsetHolds:Bool = false;

	/**
	 * If to bake the song offset when loading from a basic format to the song's note times.
	 * Turn it off if your format has some sort of song offset value.
	 */
	public var bakedOffset:Bool = true;

	/**
	 * If to import the note types as ints rather than strings.
	 * Most legacy-branching formats use strings but legacy up to 0.2.7.1 used ints.
	 */
	public var indexedTypes:Bool = false;

	/**
	 * If to offset the note lanes depending on the mustHit section value.
	 * Most legacy-branching formats use this offset.
	 */
	public var offsetMustHits:Bool = true;

	/**
	 * Resolver for FNF note type IDs.
	 */
	public var noteTypeResolver(default, null):FNFNoteTypeResolver;

	public function new(?data:FNFVsDaveFormat)
	{
		super({timeFormat: MILLISECONDS, supportsDiffs: false, supportsEvents: false});
		this.data = data;

		// Register FNF Legacy note types
		noteTypeResolver = FNFGlobal.createNoteTypeResolver();
		if (indexedTypes)
		{
			noteTypeResolver.register(0, BasicNoteType.DEFAULT);
			noteTypeResolver.register(1, BasicFNFNoteType.ALT_ANIM);
		}
	}

	public function resolveMustHitLane(mustHit:Bool, lane:Int8):Int8
	{
		return offsetMustHits ? mustHitLane(mustHit, lane) : lane;
	}

	override function fromBasicFormat(chart:BasicChart, ?diff:FormatDifficulty):FNFVsDave
	{
		var chartResolve = resolveDiffsNotes(chart, diff);
		var diff:String = chartResolve.diffs[0];
		var basicNotes:Array<BasicNote> = chartResolve.notes.get(diff);

		final meta = chart.meta;
		final initBpm = meta.bpmChanges[0].bpm;

		final notes:Array<FNFVsDaveSection> = [];
		final measures = Timing.divideNotesToMeasures(basicNotes, chart.data.events, meta.bpmChanges);

		final lanesLength:Int8 = (meta.extraData.get(LANES_LENGTH) ?? 8) <= 7 ? 4 : 8;
		final offset:Float = meta.offset;

		// Take out must hit events
		chart.data.events = FNFGlobal.filterEvents(chart.data.events);

		var lastBpm = initBpm;
		var lastMustHit:Bool = FNF_LEGACY_DEFAULT_MUSTHIT;
		var nextMustHit:Null<Bool> = null;

		var changes = meta.bpmChanges.copy();

		var timeChanges:Array<FNFVsDaveTimeChange> = [for (change in changes) {
			time: change.time,
			bpm: change.bpm,
			numerator: change.beatsPerMeasure,
			denominator: change.stepsPerBeat,
		}];

		var time = .0;

		for (measure in measures)
		{
			var mustHit:Bool = lastMustHit;

			if (nextMustHit != null)
			{
				mustHit = nextMustHit;
				nextMustHit = null;
			}

			// Push must hit events
			for (event in measure.events)
			{
				// Check if measure has a must hit event
				if (FNFGlobal.isCamFocus(event))
				{
					var eventMustHit = FNFGlobal.resolveCamFocus(event) == BF;
					var eventTime = (event.time - measure.startTime);
					if (eventTime < measure.length / 2)
					{
						mustHit = eventMustHit;
						nextMustHit = null;
					}
					else
					{
						// Event happens too late, save it for the next measure (aprox)
						nextMustHit = eventMustHit;
					}
				}
			}

			// Create legacy section
			var section:FNFVsDaveSection = {
				mustHitSection: mustHit,
				notes: [],
			}

			lastMustHit = mustHit;

			final stepCrochet:Float = offsetHolds ? Timing.stepCrochet(measure.bpm, measure.stepsPerBeat) : 0;

			// Push notes to section
			for (note in measure.notes)
			{
				final lane:Int8 = resolveMustHitLane(mustHit, (note.lane + 4 + lanesLength) % 8);
				final length:Float = note.length > 0 ? Math.max(note.length - stepCrochet, 0) : 0;

				final daveNote:FNFVsDaveNote = {
					time: note.time,
					length: note.length,
					direction: lane,
					type: note.type,
					style: VS_DAVE_DEFAULT_STYLE,
				}
				if (bakedOffset)
					daveNote.time -= offset;
				section.notes.push(daveNote);
			}

			notes.push(section);
		}

		this.data = {
			version: VS_DAVE_CHART_VERSION,
			speed: meta.scrollSpeeds.get(diff) ?? Util.mapFirst(meta.scrollSpeeds) ?? 1.0,
			notes: notes,
		}
		this.meta = {
			version: VS_DAVE_CHART_VERSION,
			songName: meta.title,
			variations: resolveCredits(meta.extraData.get(SONG_VARIATIONS)), // cause like. its also an Array<String>
			composers: resolveCredits(meta.extraData.get(SONG_ARTIST)),
			artists: resolveCredits(meta.extraData.get(VISUAL_ARTISTS)),
			charters: resolveCredits(meta.extraData.get(SONG_CHARTER)),
			coders: resolveCredits(meta.extraData.get(CODERS)),
			player: meta.extraData.get(PLAYER_1) ?? "bf",
			opponent: meta.extraData.get(PLAYER_2) ?? "dave",
			gf: chart.meta.extraData.get(PLAYER_3) ?? "gf",
			timeChanges: timeChanges,
			stage: meta.extraData.get(STAGE),
		}

		trace("oh daaave, oh daaave", this.meta);

		return this;
	}
	
	public function resolveCredits(credits:Dynamic):Array<String>
	{
		if (credits is String)
			return [cast credits];
		else
			return (credits != null) ? cast credits : [];
	}

	public function filterEvents(events:Array<BasicEvent>):Array<BasicEvent>
	{
		return FNFGlobal.filterEvents(events);
	}

	override function getNotes(?diff:String):Array<BasicNote>
	{
		var notes:Array<BasicNote> = [];
		var stepCrochet = .0; // offsetHolds ? Timing.stepCrochet(data.song.bpm, 4) : 0;

		for (section in data.notes)
		{
			//if (section.changeBPM && offsetHolds)
			//{
			//	stepCrochet = Timing.stepCrochet(section.bpm, 4);
			//}

			for (note in section.notes)
			{
				final lane:Int8 = resolveMustHitLane(section.mustHitSection, (note.direction + 4) % 8);
				final length:Float = note.length > 0 ? note.length + stepCrochet : 0;

				notes.push({
					time: note.time,
					lane: lane,
					length: length,
					type: note.type,
				});
			}
		}

		Timing.sortNotes(notes);

		return notes;
	}

	override function getEvents():Array<BasicEvent>
	{
		var events:Array<BasicEvent> = [];
		var lastMustHit:Bool = FNF_LEGACY_DEFAULT_MUSTHIT;

		// Push musthit events
		forEachSection(data.notes, (section, startTime, endTime) ->
		{
			if (section.mustHitSection != lastMustHit)
			{
				events.push(makeMustHitSectionEvent(startTime, section.mustHitSection));
				lastMustHit = section.mustHitSection;
			}
		});

		return events;
	}

	function forEachSection(sections:Array<FNFVsDaveSection>, call:(FNFVsDaveSection, Float, Float) -> Void)
	{
		var time:Float = 0;
		var crochet = .0;

		trace(meta, meta.timeChanges);
		var changes = meta.timeChanges.copy();
		for (section in sections)
		{
			while (changes.length > 0 && changes[0].time <= time)
			{
				final change = changes.shift();
				crochet = Timing.measureCrochet(change.bpm, change.numerator);
			}
			
			time += crochet;
			call(section, time, time);
		}
	}

	override function getChartMeta():BasicMetaData
	{
		var bpmChanges:Array<BasicBPMChange> = [];

		for (change in meta.timeChanges)
		{
			bpmChanges.push({
				time: change.time,
				bpm: change.bpm,
				beatsPerMeasure: change.numerator,
				stepsPerBeat: change.denominator,
			});
		}

		return {
			title: meta.songName,
			bpmChanges: bpmChanges,
			offset: 0.0,
			scrollSpeeds: Util.fillMap(diffs, data.speed),
			extraData: [
				PLAYER_1 => meta.player,
				PLAYER_2 => meta.opponent,
				NEEDS_VOICES => true,
				LANES_LENGTH => 8,
				STAGE => meta.stage,
				SONG_VARIATIONS => meta.variations,
				VISUAL_ARTISTS => meta.artists,
				CODERS => meta.coders,
			]
		}
	}

	public override function fromFile(path:String, ?meta:StringInput, ?diff:FormatDifficulty):FNFVsDave
	{
		if (meta != null)
		{
			var arr = meta.resolve();
			meta = arr;
			for (i in 0...arr.length)
				arr[i] = Util.getText(arr[i]);
		}

		return fromJson(Util.getText(path), meta, diff);
	}

	public override function fromJson(data:String, ?meta:StringInput, ?diff:FormatDifficulty):FNFVsDave
	{
		return cast super.fromJson(data, meta, diff);
	}
}

typedef FNFVsDaveFormat =
{
	version:String,
	speed:Float,
	notes:Array<FNFVsDaveSection>,
}

typedef FNFVsDaveSection =
{
	mustHitSection:Bool,
	notes:Array<FNFVsDaveNote>,
}

typedef FNFVsDaveNote =
{
	time:Float,
	direction:Int8,
	length:Float,
	type:String,
	style:String,
}

typedef FNFVsDaveMeta = 
{
	version:String,
	songName:String,
	composers:Array<String>,
	artists:Array<String>,
	charters:Array<String>,
	coders:Array<String>,
	variations:Array<String>,
	stage:String,
	player:String,
	opponent:String,
	gf:String,
	timeChanges:Array<FNFVsDaveTimeChange>,
}

typedef FNFVsDaveTimeChange = BasicTimingObject &
{
	bpm:Float,
	numerator:Float,
	denominator:Float,
}
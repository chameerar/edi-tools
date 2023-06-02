import ballerina/io;
import ballerina/edi;

map<BalType> ediToBalTypes = {
    "string": BSTRING,
    "int": BINT,
    "float": BFLOAT
};

public type EdiData record {|
    string ediName;
    string mainRecordName;
    edi:EdiSchema schema;
    map<BalRecord> generatedRecords = {};
|};

public type GenContext record {|
    // map<BalRecord> typeRecords = {};
    map<BalRecord> segmentRecords = {}; // these will be always shared
    map<BalRecord> nonSegmentRecords = {};
    map<EdiData> roots = {};
    map<BalRecord> sharedNonSegmentRecords = {};
    map<int> typeNumber = {};
    map<BalRecord> currentEdiRecords = {};
    string currentEdiName = "";
|};

# Generates all Ballerina records required to represent EDI data in the given schema and writes those to a file.
#
# + mapping - EDI schema for which records need to be generated
# + outpath - Path of the file to write generated records. This should be a .bal file.
# + return - Returns error if the record generation is not successfull
public function generateCodeToFile(edi:EdiSchema mapping, string outpath) returns error? {
    GenContext context = {currentEdiName: mapping.name, currentEdiRecords: {}};
    generateCode(mapping.name, mapping, context);
    string sRecords = "";
    foreach BalRecord rec in context.segmentRecords {
        sRecords += rec.toString() + "\n";
    }
    BalRecord[] nonSegmentRecords = context.currentEdiRecords.toArray();
    foreach BalRecord rec in nonSegmentRecords {
        sRecords += rec.toString() + "\n";
    }
    _ = check io:fileWriteString(outpath, sRecords);
}

# Generates all Ballerina records required to represent EDI data in the given schema.
#
# + mapping - EDI schema for which records need to be generated
# + context - Context for record generation. Can contain the record generation context of 
# previously processed EDI schemas, when processing an EDI schema collection (i.e. libgen).
public function generateCode(string ediName, edi:EdiSchema mapping, GenContext context) {
    context.currentEdiRecords = {};
    BalRecord rootRecord = generateRecordForUnits(mapping.segments, mapping.name, context);
    context.currentEdiRecords[rootRecord.name] = rootRecord;
    context.roots[mapping.name] = {ediName, 
            mainRecordName: rootRecord.name, 
            schema: mapping,
            generatedRecords: context.currentEdiRecords};
}

function generateRecordForUnits(edi:EdiUnitSchema[] umaps, string typeName, GenContext context) returns BalRecord {
    BalRecord sgrec = new (typeName);
    foreach edi:EdiUnitSchema umap in umaps {
        if umap is edi:EdiSegSchema {
            BalRecord srec = generateRecordForSegment(umap, context);
            sgrec.addField(srec, umap.tag, umap.maxOccurances != 1, umap.minOccurances == 0);
        } else {
            BalRecord srec = generateRecordForSegmentGroup(umap, context);
            sgrec.addField(srec, umap.tag, umap.maxOccurances != 1, umap.minOccurances == 0);
        }
    }
    return sgrec;
}

function generateRecordForSegmentGroup(edi:EdiSegGroupSchema groupmap, GenContext context) returns BalRecord {
    BalRecord? existingRecord = getMatchingNSRecord(groupmap, context);
    if existingRecord is BalRecord {
        if !context.sharedNonSegmentRecords.hasKey(existingRecord.name) {
            context.sharedNonSegmentRecords[existingRecord.name] = existingRecord;
        }
        return existingRecord;
    }
    string sgTypeName = generateTypeName(groupmap.tag, context);
    BalRecord segGroupRecord = generateRecordForUnits(groupmap.segments, sgTypeName, context);
    context.currentEdiRecords[segGroupRecord.name] = segGroupRecord;
    context.nonSegmentRecords[segGroupRecord.name] = segGroupRecord;
    return segGroupRecord;
}

function getMatchingNSRecord(edi:EdiSegGroupSchema schema, GenContext context) returns BalRecord? {
    int? maxTypeNumber = context.typeNumber[schema.tag];
    if maxTypeNumber is () {
        return ();
    }
    BalRecord? r = ();
    foreach int i in 1...maxTypeNumber {
        string recordName = startWithUppercase(schema.tag + (i == 1 ? "" : i.toString()) + "_GType");
        r = context.nonSegmentRecords[recordName];
        if r is () {
            continue;
        }
        if matchSchemaWithRecord(schema, r) {
            return r;
        }
    }
    return ();
}

function matchSchemaWithRecord(edi:EdiSegGroupSchema schema, BalRecord balRecord) returns boolean {
    if schema.segments.length() != balRecord.fields.length() {
        return false;
    }
    BalField[] bFields = balRecord.fields.slice(0);
    foreach edi:EdiUnitSchema unitSchema in schema.segments {
        boolean fieldMatched = false;
        foreach int i in 0...(bFields.length() - 1) {
            BalField bField = bFields[i];
            BalType fieldType = bField.btype;
            if fieldType is BalBasicType {
                return false;
            }
            if unitSchema is edi:EdiSegSchema {
                if startWithUppercase(unitSchema.tag + "_Type") == fieldType.name {
                    fieldMatched = true;
                    _ = bFields.remove(i);
                    break;
                }
            } else {
                if startWithUppercase(unitSchema.tag + "_GType") == fieldType.name && 
                    matchSchemaWithRecord(unitSchema, fieldType) {
                    _ = bFields.remove(i);
                    fieldMatched = true;
                    break;
                }
            }    
        }
        if !fieldMatched {
            return false;
        }
    }
    return true;
}

function generateRecordForSegment(edi:EdiSegSchema segmap, GenContext context) returns BalRecord {
    string sTypeName = startWithUppercase(segmap.tag + "_Type");
    BalRecord? erec = context.segmentRecords[sTypeName];
    if erec is BalRecord {
        return erec;
    }
    BalRecord srec = new (sTypeName);
    foreach edi:EdiFieldSchema emap in segmap.fields {
        BalType? balType = ediToBalTypes[emap.dataType];
        if emap.dataType == edi:COMPOSITE {
            balType = generateRecordForComposite(emap, context);
        }

        if balType is BalType {
            srec.addField(balType, emap.tag, emap.repeat, !emap.required);
        }
    }
    context.segmentRecords[srec.name] = srec;
    return srec;
}

function generateRecordForComposite(edi:EdiFieldSchema emap, GenContext context) returns BalRecord {
    string cTypeName = generateTypeName(emap.tag, context);
    BalRecord crec = new (cTypeName);
    foreach edi:EdiComponentSchema submap in emap.components {
        BalType? balType = ediToBalTypes[submap.dataType];
        if balType is BalType {
            crec.addField(balType, submap.tag, false, !submap.required);
        }
    }
    context.currentEdiRecords[cTypeName] = crec;
    return crec;
}

function startWithUppercase(string s) returns string {
    string newS = s.trim();
    if newS.length() == 0 {
        return s;
    }
    string firstLetter = newS.substring(0, 1);
    newS = firstLetter.toUpperAscii() + newS.substring(1, newS.length());
    return newS;
}

function generateTypeName(string tag, GenContext context) returns string {
    int? num = context.typeNumber[tag];
    if num is int {
        int newNum = num + 1;
        context.typeNumber[tag] = newNum;
        return startWithUppercase(string `${tag}_${newNum}_GType`);
    } else {
        int newNum = 1;
        context.typeNumber[tag] = newNum;
        return startWithUppercase(tag + "_GType");
    }
}

public class BalRecord {
    string name;
    BalField[] fields = [];
    boolean closed = true;
    boolean publicRecord = true;

    function init(string name) {
        self.name = name;
    }

    function addField(BalType btype, string name, boolean array, boolean optional) {
        self.fields.push(new BalField(btype, name, array, optional));
    }

    function toString(boolean... anonymous) returns string {
        if anonymous.length() == 0 {
            anonymous.push(false);
        }
        string recString = string `record {${self.closed ? "|" : ""}` + "\n";
        foreach BalField f in self.fields {
            recString += "   " + f.toString(anonymous[0]) + "\n";
        }
        recString += string `${self.closed ? "|" : ""}};` + "\n";

        if !anonymous[0] {
            recString = string `${self.publicRecord ? "public" : ""} type ${self.name} ${recString}`;
        }
        return recString;
    }
}

class BalField {
    string name;
    BalType btype;
    boolean array = false;
    boolean optional = true;

    function init(BalType btype, string name, boolean array, boolean optional) {
        self.btype = btype;
        self.name = name;
        self.array = array;
        self.optional = optional;
    }

    function toString(boolean... anonymous) returns string {
        if anonymous.length() == 0 {
            anonymous.push(false);
        }

        BalType t = self.btype;
        string typeName = "";
        if t is BalRecord {
            if anonymous[0] {
                typeName = t.toString(true);
            } else {
                typeName = t.name;
            }
        } else {
            typeName = t.toString();
        }
        // string typeName = t is BalRecord? t.name : t.toString();
        return string `${typeName}${(self.optional && !self.array && self.btype != BSTRING) ? "?" : ""}${self.array ? "[]" : ""} ${self.name}${(self.optional && !self.array) ? "?" : ""}${self.array ? " = []" : ""};`;
    }
}

public type BalType BalBasicType|BalRecord;

public enum BalBasicType {
    BSTRING = "string", BINT = "int", BFLOAT = "float", BBOOLEAN = "boolean"
}

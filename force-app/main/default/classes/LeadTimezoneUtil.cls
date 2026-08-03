/**
 * LeadTimezoneUtil — resolves a recipient's local IANA timezone for quiet-hours (8am–9pm local)
 * enforcement. Resolution order: phone area code -> US state -> Office__c default -> company default (ET).
 * Area codes that straddle two zones are mapped to their predominant zone; the state fallback covers gaps.
 * Pure/stateless — safe to call from a before-save trigger for every Lead.
 */
public with sharing class LeadTimezoneUtil {

    public static final String ET = 'America/New_York';    // Eastern
    public static final String CT = 'America/Chicago';     // Central
    public static final String MT = 'America/Denver';      // Mountain
    public static final String AZ = 'America/Phoenix';     // Arizona (no DST)
    public static final String PT = 'America/Los_Angeles'; // Pacific
    public static final String AK = 'America/Anchorage';   // Alaska
    public static final String HI = 'Pacific/Honolulu';    // Hawaii
    public static final String DEFAULT_TZ = ET;            // HFS HQ / all four offices are Eastern

    private static final Map<String, String> AREA = buildAreaMap();
    private static final Map<String, String> STATE_TZ = buildStateMap();
    private static final Map<String, String> STATE_NAMES = buildStateNameMap();
    private static final Map<String, String> OFFICE = new Map<String, String>{
        'HFS_TPA' => ET, 'HFS_MIA' => ET, 'HFS_NJ' => ET, 'HFS_NY' => ET
    };

    /** IANA tz from area code, else state, else office default, else ET. Never null. */
    public static String resolve(String phone, String state, String officeCode) {
        String ac = areaCode(phone);
        if (ac != null && AREA.containsKey(ac)) return AREA.get(ac);
        String st = normalizeState(state);
        if (st != null && STATE_TZ.containsKey(st)) return STATE_TZ.get(st);
        if (String.isNotBlank(officeCode) && OFFICE.containsKey(officeCode)) return OFFICE.get(officeCode);
        return DEFAULT_TZ;
    }

    /** First 3 digits of the 10-digit NANP number (drops a leading country-code 1). Null if not derivable. */
    @TestVisible
    static String areaCode(String phone) {
        if (String.isBlank(phone)) return null;
        String d = phone.replaceAll('[^0-9]', '');
        if (d.length() == 11 && d.startsWith('1')) d = d.substring(1);
        if (d.length() < 10) return null;
        return d.substring(0, 3);
    }

    /** 2-letter uppercase state code from a 2-letter code or a full state name; null if unrecognized. */
    @TestVisible
    static String normalizeState(String state) {
        if (String.isBlank(state)) return null;
        String s = state.trim().toUpperCase();
        if (s.length() == 2 && STATE_TZ.containsKey(s)) return s;
        return STATE_NAMES.containsKey(s) ? STATE_NAMES.get(s) : null;
    }

    private static void put(Map<String, String> m, String tz, List<String> codes) {
        for (String c : codes) m.put(c, tz);
    }

    private static Map<String, String> buildAreaMap() {
        Map<String, String> m = new Map<String, String>();
        // Eastern
        put(m, ET, new List<String>{
            '202','203','207','212','215','216','220','223','234','240','252','267','272','276','283',
            '301','302','304','305','313','315','321','326','330','332','336','339','347','351','352',
            '380','386','401','404','407','410','412','413','419','423','434','440','443','445','470',
            '475','478','484','502','508','513','516','517','518','540','551','561','567','570','571',
            '585','586','601','603','606','607','609','610','614','617','626','631','636','640','646',
            '667','678','680','681','689','703','704','706','716','717','718','724','732','734','740',
            '743','754','757','762','770','771','772','774','781','786','802','803','804','810','813',
            '814','828','835','838','839','843','845','848','850','854','857','859','860','862','863',
            '864','865','878','904','908','910','912','914','917','919','929','930','937','938','941',
            '943','947','948','954','959','973','978','980','984','989'
        });
        // Central
        put(m, CT, new List<String>{
            '205','210','214','217','219','224','225','228','251','254','256','262','270','281','309',
            '312','314','316','318','319','320','327','331','334','337','346','361','364','405','409',
            '414','417','430','447','463','464','469','479','483','501','504','507','512','515','534',
            '539','557','563','572','573','580','601','605','608','612','615','618','620','629','630',
            '636','641','651','659','660','662','682','701','708','712','713','715','726','730','731',
            '737','763','769','773','779','785','806','815','816','817','830','832','847','870','872',
            '901','903','913','918','920','931','936','940','945','952','956','972','975','979','985'
        });
        // Mountain
        put(m, MT, new List<String>{
            '303','307','308','385','406','435','505','575','719','720','801','970','983','986'
        });
        // Arizona (no DST)
        put(m, AZ, new List<String>{ '480','520','602','623','928' });
        // Pacific
        put(m, PT, new List<String>{
            '206','208','209','213','253','279','310','323','341','360','408','415','424','425','442',
            '458','503','509','510','530','541','559','562','564','619','628','650','657','661','669',
            '702','707','714','725','747','760','775','805','818','820','831','840','858','909','916',
            '925','949','951','971'
        });
        // Alaska / Hawaii
        put(m, AK, new List<String>{ '907' });
        put(m, HI, new List<String>{ '808' });
        return m;
    }

    /** 2-letter state -> predominant IANA tz (straddling states mapped to their most-populous zone). */
    private static Map<String, String> buildStateMap() {
        Map<String, String> m = new Map<String, String>();
        for (String s : new List<String>{'CT','DE','DC','FL','GA','IN','KY','ME','MD','MA','MI','NH',
                'NJ','NY','NC','OH','PA','RI','SC','VT','VA','WV'}) m.put(s, ET);
        for (String s : new List<String>{'AL','AR','IL','IA','KS','LA','MN','MS','MO','NE','ND','OK',
                'SD','TN','TX','WI'}) m.put(s, CT);
        for (String s : new List<String>{'CO','ID','MT','NM','UT','WY'}) m.put(s, MT);
        m.put('AZ', AZ);
        for (String s : new List<String>{'CA','NV','OR','WA'}) m.put(s, PT);
        m.put('AK', AK);
        m.put('HI', HI);
        return m;
    }

    private static Map<String, String> buildStateNameMap() {
        return new Map<String, String>{
            'ALABAMA'=>'AL','ALASKA'=>'AK','ARIZONA'=>'AZ','ARKANSAS'=>'AR','CALIFORNIA'=>'CA',
            'COLORADO'=>'CO','CONNECTICUT'=>'CT','DELAWARE'=>'DE','DISTRICT OF COLUMBIA'=>'DC',
            'FLORIDA'=>'FL','GEORGIA'=>'GA','HAWAII'=>'HI','IDAHO'=>'ID','ILLINOIS'=>'IL',
            'INDIANA'=>'IN','IOWA'=>'IA','KANSAS'=>'KS','KENTUCKY'=>'KY','LOUISIANA'=>'LA',
            'MAINE'=>'ME','MARYLAND'=>'MD','MASSACHUSETTS'=>'MA','MICHIGAN'=>'MI','MINNESOTA'=>'MN',
            'MISSISSIPPI'=>'MS','MISSOURI'=>'MO','MONTANA'=>'MT','NEBRASKA'=>'NE','NEVADA'=>'NV',
            'NEW HAMPSHIRE'=>'NH','NEW JERSEY'=>'NJ','NEW MEXICO'=>'NM','NEW YORK'=>'NY',
            'NORTH CAROLINA'=>'NC','NORTH DAKOTA'=>'ND','OHIO'=>'OH','OKLAHOMA'=>'OK','OREGON'=>'OR',
            'PENNSYLVANIA'=>'PA','RHODE ISLAND'=>'RI','SOUTH CAROLINA'=>'SC','SOUTH DAKOTA'=>'SD',
            'TENNESSEE'=>'TN','TEXAS'=>'TX','UTAH'=>'UT','VERMONT'=>'VT','VIRGINIA'=>'VA',
            'WASHINGTON'=>'WA','WEST VIRGINIA'=>'WV','WISCONSIN'=>'WI','WYOMING'=>'WY'
        };
    }
}

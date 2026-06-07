namespace Shrike;

public struct BinaryH1HeaderData
{
    public PinnedByteSequence HttpMethod;
    
    public PinnedByteSequence Route;
    
    public PinnedByteSequence QueryParameters;
    
    public bool HasQueryParameters => QueryParameters.Length > 0;

    public PinnedByteSequence Headers;
}